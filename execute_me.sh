#!/bin/bash

ACTION=$1
CLIENT_ID=$2
S3_CURRENT_LOCATION=$3
CAPTAIN_JOB=$4

# run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root";
  exit
fi

# create work dir
WORK_LOCATION='/var/tmp/cloud_learn'
mkdir -p ${WORK_LOCATION}

# default variables
ACTIVITY_LOG="${WORK_LOCATION}/${CLIENT_ID}_${ACTION}.log"
FAILED_LOG="${WORK_LOCATION}/${CLIENT_ID}_${ACTION}_faled.log"
IN_PROGRESS_FLAG_FILE="${WORK_LOCATION}/in_progress.txt"
DATE=`date +%Y-%m-%d_%H-%M-%S`

# create the .zip files location
WORK_LOCATION_FILES=${WORK_LOCATION}/files
mkdir -p ${WORK_LOCATION_FILES}
chown bbuser:bbuser ${WORK_LOCATION_FILES}

## S3 Variables
S3_ROOT_DIR="s3://learn-content-store/${CLIENTID}/${ACTION}/${CAPTAIN_JOB}"
S3_LOG_DIR="${S3_ROOT_DIR}/logs/"
S3_FILES="${S3_ROOT_DIR}/files/"
S3_FEED="${S3_ROOT_DIR}/feed.txt"
S3_IN_PROGRESS_FILE="${S3_ROOT_DIR}/in_progress.txt"
S3_ACTIVITY_LOG="${WORK_LOCATION}/S3_${CLIENT_ID}_${ACTION}.log"

# download the in progress flag to know where i am and if its a course
aws s3 cp $S3_IN_PROGRESS_FILE $IN_PROGRESS_FLAG >> ${S3_ACTIVITY_LOG}

# function in case it gets exited (stopped) for whatever reason
function trap2exit (){

  echo "\nExiting...";
  aws s3 mv $IN_PROGRESS_FLAG_FILE  >> $S3_ACTIVITY_LOG
  # need to upload the status
  # need to save the logs before they get lost
  # need to save the files if any were created
  #aws s3 cp ${ACTIVITYLOG} s3://learn-content-store/${CLIENTID}/${ACTION}/
  exit 0;
}

# trap if if we kill it
trap trap2exit SIGHUP SIGINT SIGTERM

# add jq to the ubuntu repo 16.04
echo "deb http://us.archive.ubuntu.com/ubuntu xenial main universe" >> /etc/apt/sources.list

# update the repos and install dependencies
sudo apt-get update
sudo apt-get install -y inotify-tools dos2unix jq

# modify the heap for the archive process to have 12G
# if the instance is bigger, this can be customizable
if [ "$(grep -c '$OPTS -Xmx12g'   /usr/local/blackboard/apps/content-exchange/bin/batch_ImportExport.sh)" -eq 0 ]; then
  sed -i '/OPTS=""/a OPTS="$OPTS -Xmx12g"' /usr/local/blackboard/apps/content-exchange/bin/batch_ImportExport.sh
fi


if [[ "$ACTION" == "import" || "$ACTION" == "restore" ]]; then

  # START OF THE PROCESS AND RESIZE OF THE VOLUME
  if [ ! -f $IN_PROGRESS_FLAG || $IN_PROGRESS_FLAG -eq 0 ]; then
    echo 0 > $IN_PROGRESS_FLAG_FILE
    # get directory size in s3
    # Bytes/MiB/KiB/GiB/TiB/PiB/EiB types
    files_size=`aws s3 ls ${S3CURRENTLOCATION} --summarize --human-readable --profile cloudbb | tail -n1 | awk '{print $3,$4}'`
    files_size_type=`echo $files_size | awk '{print $2}'`
    #files_size_count=`echo $files_size | awk '{print $1}'`
    files_size_count=99.9
    files_size_count_rounded=`echo "($files_size_count+0.5)/1" | bc`
    if [[ "$files_size_type" == "GiB" ]]; then
      if [ "$files_size_count_rounded" -le "100" ]; then
        required_size=100
      else
        required_size=$((100 + $files_size_count_rounded))

      fi
    elif [[ "$files_size_type" == "MiB" ]]; then
      required_size=100
    else
      echo "Not accepting Tera / Penta / Exbi - Bytes at this time.. exiting"
      exit 1
    fi

    # resize volume
    region=`curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | awk -F'"' '/\"region\"/ { print $4 }'`
    instance_id=`curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | awk -F'"' '/\"instanceId\"/ { print $4 }'`
    volume_id=`aws ec2 describe-instances --instance-id $instance_id --region $region | jq '.Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId'`
    aws ec2 modify-volume --volume-id $volume_id --size $required_size

    # set in progress flag
    echo 1 > $IN_PROGRESS_FLAG_FILE
  else
    in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  fi

  # DOWNLOAD OF FILES
  if [[ $in_progress_flag -eq 1 ]]; then
    # download files
    aws s3 sync ${S3_CURRENT_LOCATION} ${WORK_LOCATION_FILES} >> $S3_ACTIVITY_LOG
    # set in progress flag
    echo 2 > $IN_PROGRESS_FLAG_FILE
  fi

  # CHECK FOR DUPLICATES AND BROKEN FILES
  if [[ $in_progress_flag -eq 2 ]]; then
    # test them / check for:
    echo "Looking for broken or corrupted .zip files..."
    BROKEN_FILES="${WORK_LOCATION}/${CLIENT_ID}_${ACTION}_broken_files.txt"
    COURSE_IDS="${WORK_LOCATION}/${CLIENT_ID}_${ACTION}_course_ids.txt"
    DUPLICATES="${WORK_LOCATION}/${CLIEN_TID}_${ACTION}_duplicate_files.txt"

    # courses that come from other LMS get "imported not restore"
    # only courses coming from Bb have the .bb-package-info
    ## bad zip files
    for i in `ls $WORK_LOCATION_FILES/*.zip`; do
      unzip -t $i &> /dev/null
      if [ $? -ne 0 ] ; then
        echo "Course $i is broken..."
        echo "$i BROKEN" >> $BROKEN_FILES
      else
        if [[ "$file" =~ "ArchiveFile" || "$file" =~ "ExportFile" ]]; then
          unzip -c $i .bb-package-info | grep cx.config.course.id | awk -F= -v var=$WORK_LOCATION_FILES/$i '{print $2",",var}' >> $COURSE_IDS
        # if it doesnt come from Bb the course id is just the name of the zip file
        else
          echo $i | awk -v var=$WORK_LOCATION_FILES/$i -F'.zip' '{print $2",",var}' >> $COURSE_IDS
        fi
      fi
    done

    ## duplicates
    echo "Looking for duplicate files..."
    for i in `cat $COURSE_IDS | awk '{print $2}' | sort | uniq -d`; do
      grep $i $COURSE_IDS
    done > $DUPLICATES

    echo 3 > $IN_PROGRESS_FLAG_FILE
  fi

  # CREATION OF MONITOR FILE
  if [[ $in_progress_flag -eq 3 ]]; then
    # create monitor file
    # The following will
    ## Create a script to monitor the file location
    ## Upload it to S3 as soon as the second file appears
    ### Files don't get created until they are completed and next course gets processed
    ## Removes the file from the location so we don't fill the space up.
    cat > ${WORK_LOCATION}/monitor_action_bb_logs.sh <<- "EOF"
    #!/bin/bash
    ACTION=$1
    CLIENT_ID=$2
    WORK_LOCATION=$3
    S3_ROOT_DIR=$4
    COUNTER=0
    IN_PROGRESS_FLAG_FILE="${WORK_LOCATION}/in_progress.txt"
    S3_ACTIVITY_LOG="${WORK_LOCATION}/S3_${CLIENTID}_${ACTION}.log"

    inotifywait -m /usr/local/blackboard/logs/content-exchange/ -e create | while read path action file; do

      if [[ "$file" =~ "BatchCxCmd" && "$file" =~ "details.txt" ]]; then
        COUNTER=$((COUNTER+1))
        COMPLETED_COURSE=`ls -t /usr/local/blackboard/logs/content-exchange/BatchCxCmd* | tail -n 2| grep details.txt | cut -d'_' -f3- | awk -F'_details.txt' '{print $1}'`
        if [[ $COUNTER -eq 2 ]]; then
          COUNTER=1
          echo $COMPLETED_COURSE > $IN_PROGRESS_FLAG_FILE
          # upload the flag file
          aws s3 mv $IN_PROGRESS_FLAG_FILE  >> $S3_ACTIVITY_LOG
          # upload logs cause they can be deleted
          for file in `ls -t /usr/local/blackboard/logs/content-exchange/*${COMPLETED_COURSE}*`; do
            aws s3 mv $file ${S3_ROOT_DIR}/logs/
          done

        fi
      fi
    done
EOF

    echo 4 > $IN_PROGRESS_FLAG_FILE

  fi

  # CREATION OF FEED FILE & AND UPLOAD IT FOR BACKUP
  # regular expression for any number
  re='^[0-9]+$'
  if [[ $in_progress_flag -eq 4 ]]; then
    #feed format
    #course_id,/path/to/file.zip
    FEED_FILE=${WORK_LOCATION}/feed.txt
    cat $COURSE_IDS > $FEED_FILE
    # upload feed file
    aws s3 cp $FEED_FILE $S3_FEED

  # check if the flag is a course
  elif [[ ! $in_progress_flag =~ $re ]] 2>/dev/null; then
    aws s3 cp $S3_FEED $FEED_FILE
    # create new feed file from that course onwards
    sed -i '/'$in_progress_flag'/,$!d' $FEED_FILE
    aws s3 cp $FEED_FILE $S3_FEED

  fi

  # EXECUTION
  # we always execute, ideally the last step will always be either 4 or a course id, that is set in the monitor

  # invoke the monitor
  chmod +x ${WORK_LOCATION}/monitor_action_bb_logs.sh
  # and we let it run in the background
  ${WORK_LOCATION}/monitor_action_bb_logs.sh ${ACTION} ${CLIENT_ID} ${WORK_LOCATION} ${S3_ROOT_DIR} &

  # clean the logs that will be monitored

  rm -rf /usr/local/blackboard/logs/content-exchange/BatchCxCmd_*
  mv /usr/local/blackboard/logs/content-exchange/content-exchange-log.txt /usr/local/blackboard/logs/content-exchange/content-exchange-log-${ACTION}.txt.${DATE}

  # command to execute
  sudo -u bbuser /usr/local/blackboard/apps/content-exchange/bin/batch_ImportExport.sh -f ${FEED_FILE}-l 1 -t ${ACTION} > ${WORK_LOCATION}/batch_${FILE}.log







elif [[ "$ACTION" == "archive" || "$ACTION" == "export" ]]; then
  # need to increase the volume mounted to the required space
  echo $ACTION
fi
