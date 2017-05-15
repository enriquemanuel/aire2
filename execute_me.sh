#!/bin/bash

ACTION=$1
CLIENT_ID=$2
S3_CURRENT_LOCATION=$3
CAPTAIN_JOB=$4
FEED_FILE_SET=$5 #boolean flag
RENAME_SET=$6 #boolean flag

# timer
script_start_time=`date +%s`


# run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root";
  exit 1
fi

# Local variables
WORK_LOCATION='/var/tmp/cloud_learn'
ACTIVITY_LOG="${WORK_LOCATION}/${CLIENT_ID}_${ACTION}.log"
FAILED_LOG="${WORK_LOCATION}/${CLIENT_ID}_${ACTION}_faled.log"
IN_PROGRESS_FLAG_FILE="${WORK_LOCATION}/in_progress.txt"
FEED_FILE=${WORK_LOCATION}/feed.txt
DATE=`date +%Y-%m-%d_%H-%M-%S`
re='^[0-9]+$'

## S3 Variables
S3_ROOT_DIR="s3://learn-content-store/${CLIENT_ID}/${ACTION}/${CAPTAIN_JOB}"
S3_LOG_DIR="${S3_ROOT_DIR}/logs/"
S3_FILES="${S3_ROOT_DIR}/files/"
S3_FEED="${S3_ROOT_DIR}/feed.txt"
S3_IN_PROGRESS_FILE="${S3_ROOT_DIR}/in_progress.txt"
S3_ACTIVITY_LOG="${WORK_LOCATION}/S3_${CLIENT_ID}_${ACTION}.log"


aws s3 cp $S3_IN_PROGRESS_FILE $IN_PROGRESS_FLAG_FILE > /dev/null 2>&1
# was there a in progress file?
if [ $? -eq 0 ]; then
  # if yes, lets check for the working dir if its there
  if [ -d $WORK_LOCATION ]; then
    # if yes, lets get the value from the in progress file
    in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  else
    # if no folder, lets...
    # no work location exists but in progress file exists
    mkdir -p ${WORK_LOCATION}
    in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
    # now lets check if the in progres flag is a course
    if [[ ! $in_progress_flag =~ $re ]] 2>/dev/null; then
      # if yes, we need to...
      # need to create the need feed file and upload it
      $FEED_FILE_SET="yes"
      aws s3 cp $S3_FEED $FEED_FILE --region $region
      sed -i '/'$in_progress_flag'/,$!d' $FEED_FILE
      aws s3 mv $FEED_FILE $S3_FEED --region $region
      echo 0 > $IN_PROGRESS_FLAG_FILE
    else
      # if not, lets set it depending on the action
      if [[ "$ACTION" == "import" || "$ACTION" == "restore" ]]; then
        echo 0 > $IN_PROGRESS_FLAG_FILE
      elif [[ "$ACTION" == "archive" || "$ACTION" == "export" ]]; then
        echo 1 > $IN_PROGRESS_FLAG_FILE
      fi # finish action
    fi # finish in progress flag regular expression
  fi # finish the work location
else
  if [ -d $WORK_LOCATION ]; then
    # if yes, lets get the value from the in progress file
    in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  else
    mkdir -p ${WORK_LOCATION}
    if [[ "$ACTION" == "import" || "$ACTION" == "restore" ]]; then
      echo 0 > $IN_PROGRESS_FLAG_FILE
    elif [[ "$ACTION" == "archive" || "$ACTION" == "export" ]]; then
      echo 1 > $IN_PROGRESS_FLAG_FILE
    fi # finish action
  fi
fi # finish task

# create the .zip files location
WORK_LOCATION_FILES=${WORK_LOCATION}/files
mkdir -p ${WORK_LOCATION_FILES}
chown bbuser:bbuser ${WORK_LOCATION_FILES}

WORK_LOCATION_FILES_BAD=${WORK_LOCATION}/files_bad
mkdir -p ${WORK_LOCATION_FILES_BAD}
chown bbuser:bbuser ${WORK_LOCATION_FILES_BAD}

WORK_LOCATION_FILES_DUPLICATE=${WORK_LOCATION}/files_duplicate
mkdir -p ${WORK_LOCATION_FILES_DUPLICATE}
chown bbuser:bbuser ${WORK_LOCATION_FILES_DUPLICATE}



## RUNTIME VARIABLES
region=`curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | awk -F'"' '/\"region\"/ { print $4 }'`
instance_id=`curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | awk -F'"' '/\"instanceId\"/ { print $4 }'`
volume_id=`aws ec2 describe-instances --instance-id $instance_id --region $region | jq '.Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId' | tr -d '"'`


# function in case it gets exited (stopped) for whatever reason
function trap2exit (){

  echo "\nExiting...";
  aws s3 cp $IN_PROGRESS_FLAG_FILE $S3_IN_PROGRESS_FILE --region $region
  aws s3 cp $FEED_FILE $S3_FEED --region $region
  for log_file in `ls /usr/local/blackboard/logs/content-exchange/content-exchange-log.txt*`; do
    aws s3 cp $log_file $S3_LOG_DIR --region $region
  done
  end_time=`date +%s`
  echo "    script took `expr $end_time - $start_time` s."
  exit 0;
}

# trap if if we kill it
trap trap2exit SIGHUP SIGINT SIGTERM

# add jq to the ubuntu repo 16.04
echo "deb http://us.archive.ubuntu.com/ubuntu xenial main universe" >> /etc/apt/sources.list

# update the repos and install dependencies
echo "Installing dependencies..."
sudo apt-get update > /dev/null 2>&1
sudo apt-get install -y inotify-tools dos2unix jq > /dev/null 2>&1
sudo pip install pip install --upgrade --user awscli > /dev/null 2>&1

echo "Killing old monitors..."
sudo killall inotifywait > /dev/null 2>&1

# modify the heap for the archive process to have 12G
# if the instance is bigger, this can be customizable
if [ "$(grep -c '$OPTS -Xmx13g'   /usr/local/blackboard/apps/content-exchange/bin/batch_ImportExport.sh)" -eq 0 ]; then
  sed -i '/OPTS=""/a OPTS="$OPTS -Xmx13g"' /usr/local/blackboard/apps/content-exchange/bin/batch_ImportExport.sh
fi


if [[ "$ACTION" == "import" || "$ACTION" == "restore" ]]; then
  echo ""
  echo "Starting Import/Restore Process"

  # START OF THE PROCESS AND RESIZE OF THE VOLUME
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 0 ]] 2>/dev/null; then
    echo "0" > $IN_PROGRESS_FLAG_FILE

    # get directory size in s3
    # Bytes/MiB/KiB/GiB/TiB/PiB/EiB types
    echo "  Reading the required volume size..."
    files_size=`aws s3 ls ${S3_CURRENT_LOCATION} --summarize --human-readable --region $region | tail -n1 | awk '{print $3,$4}'`
    files_size_type=`echo $files_size | awk '{print $2}'`
    files_size_count=`echo $files_size | awk '{print $1}'`
    files_size_count_rounded=`echo "($files_size_count+0.5)/1" | bc`
    if [[ "$files_size_type" == "GiB" ]]; then
      if [ "$files_size_count_rounded" -le "100" ]; then
        required_size=101
      else
        required_size=$((100 + $files_size_count_rounded))
      fi
    elif [[ "$files_size_type" == "MiB" ]]; then
      required_size=101
    else
      echo "    Not accepting Tera / Penta / Exbi - Bytes at this time.. exiting"
      exit 1
    fi

    echo "  Modifying the volume size..."
    # resize volume
    #aws ec2 modify-volume --volume-id $volume_id --size $required_size --region $region
    if [ $? -ne 0 ] ; then
      echo "    There was a problem modifying the volume. Exiting..."
      exit 1
    fi

    # set in progress flag
    echo 1 > $IN_PROGRESS_FLAG_FILE
  fi


  # DOWNLOAD OF FILES
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 1 ]] 2>/dev/null; then
    echo "  Downloading Files from S3..."
    # download files
    start_time=`date +%s`
    aws s3 sync ${S3_CURRENT_LOCATION} ${WORK_LOCATION_FILES} --region $region >> $S3_ACTIVITY_LOG
    end_time=`date +%s`
    echo "    download took `expr $end_time - $start_time` s."
    # set in progress flag
    echo 2 > $IN_PROGRESS_FLAG_FILE
  fi

  # CHECK FOR DUPLICATES AND BROKEN FILES
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 2 ]] 2>/dev/null; then

    BROKEN_FILES="${WORK_LOCATION}/${CLIENT_ID}_${ACTION}_broken_files.txt"
    COURSE_IDS="${WORK_LOCATION}/${CLIENT_ID}_${ACTION}_course_ids.txt"
    DUPLICATES="${WORK_LOCATION}/${CLIENT_ID}_${ACTION}_duplicate_files.txt"

    # if no feed file was provided
    if [[ "$FEED_FILE_SET" == "no" ]]; then
      # test them / check for:
      echo "  No Client Feed file, creating one from the files..."
      echo "  Looking for broken or corrupted .zip files..."

      # courses that come from other LMS get "imported not restore"
      # only courses coming from Bb have the .bb-package-info
      ## bad zip files
      for i in `ls $WORK_LOCATION_FILES/*.zip`; do
        unzip -t $i &> /dev/null
        if [ $? -ne 0 ] ; then
          echo "    Course $i is broken..."
          echo "$i" >> $BROKEN_FILES
          mv $WORK_LOCATION_FILES/$i $WORK_LOCATION_FILES_BAD/$i
        else
          if [[ "$RENAME_SET" == "no" ]]; then
            if [[ "$i" =~ "ArchiveFile" || "$i" =~ "ExportFile" ]]; then
              unzip -c $i .bb-package-info | grep cx.config.course.id | awk -F= -v var=$i '{print $2",",var}' >> $COURSE_IDS
              # if it doesnt come from Bb the course id is just the name of the zip file
            else
              echo $i | awk -v var=$WORK_LOCATION_FILES/$i -F'.zip' '{print $2",",var}' >> $COURSE_IDS
            fi
          elif [[ "$RENAME_SET" == "yes" ]]; then
            if [[ "$i" =~ "ArchiveFile" || "$i" =~ "ExportFile" ]]; then
              unzip -c $i .bb-package-info | grep cx.config.course.id | awk -F= -v var="$i" '{print $2"_recover,",var}' >> $COURSE_IDS
              # if it doesnt come from Bb the course id is just the name of the zip file
            else
              echo $i | awk -v var="$i" -F'.zip' '{print $2"recover,",var}' >> $COURSE_IDS
            fi
          fi
        fi
      done


      ## duplicates
      echo "  Looking for duplicate files..."
      for i in `cat $COURSE_IDS | awk '{print $2}' | sort | uniq -d`; do
        grep $i $COURSE_IDS
      done > $DUPLICATES

      echo 3 > $IN_PROGRESS_FLAG_FILE

    # user provided feed file
    elif [[ "$FEED_FILE_SET" == "yes" ]]; then
      echo "  Downloading client provided feed file..."
      aws s3 cp $S3_FEED $FEED_FILE --region $region >> ${S3_ACTIVITY_LOG}
      echo "  Client Provided feed file"
      echo "  Looking for broken or corrupted .zip files..."
      columns=`awk '{print NF}' $FEED_FILE | sort -nu | tail -n 1`


      # feed file only contains course id
      if [[ $columns -eq 1 ]]; then
      # only test files specified in the feed file
        for course_id in `cat $FEED_FILE`; do
          file=`ls $WORK_LOCATION_FILES/ | grep $course_id | head -n1`
          unzip -t $WORK_LOCATION_FILES/$file &> /dev/null
          if [ $? -ne 0 ] ; then
            echo "    Course $course_id is broken..."
            echo "$course_id" >> $BROKEN_FILES
          else
            if [[ "$file" =~ "ArchiveFile" || "$file" =~ "ExportFile" ]]; then
              unzip -c $WORK_LOCATION_FILES/$file .bb-package-info | grep cx.config.course.id | awk -F= -v var=$WORK_LOCATION_FILES/$file '{print $2",",var}' >> $COURSE_IDS
              # if it doesnt come from Bb the course id is just the name of the zip file
            else
              echo $course_id | awk -v var=$WORK_LOCATION_FILES/$file -F'.zip' '{print $2",",var}' >> $COURSE_IDS
            fi

          fi
        done


      # feed file with course_id, zip_file name
      elif [[ $columns -eq 2 ]]; then
        for zip_file in `cat $FEED_FILE | awk '{print $2}'`; do
          file=`ls $WORK_LOCATION_FILES/ | grep $zip_file | head -n1`
          diff_course_id=`grep $zip_file $FEED_FILE | awk '{print $1}'`
          unzip -t $WORK_LOCATION_FILES/$zip_file &> /dev/null
          if [ $? -ne 0 ] ; then
            echo "    Course $zip_file is broken..."
            echo "$zip_file" >> $BROKEN_FILES
          else
            echo "$diff_course_id $WORK_LOCATION_FILES/$zip_file" >> $COURSE_IDS
          fi
        done
      else
        echo "    Incorrect feed file..."
        exit 1
      fi

      echo "  Looking for duplicate files..."
      for i in `cat $FEED_FILE | awk '{print $1}' | sort | uniq -d`; do
        grep $i $FEED_FILE
      done > $DUPLICATES

      echo 3 > $IN_PROGRESS_FLAG_FILE
    fi
  fi


  # CREATION OF MONITOR FILE
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 3 ]] 2>/dev/null; then
    echo "  Creating Monitor file..."
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
    REGION=$5
    COUNTER=0
    WORK_COUNTER_INT=0
    WORK_COUNTER_TOTAL=`wc -l $WORK_LOCATION/feed.txt | awk '{print $1}'`
    IN_PROGRESS_FLAG_FILE="${WORK_LOCATION}/in_progress.txt"
    S3_IN_PROGRESS_FILE="${S3_ROOT_DIR}/in_progress.txt"
    S3_ACTIVITY_LOG="${WORK_LOCATION}/S3_${CLIENT_ID}_${ACTION}.log"

    inotifywait -m /usr/local/blackboard/logs/content-exchange/ -e create | while read path action file; do

      if [[ "$file" =~ "BatchCxCmd" && "$file" =~ "details.txt" ]]; then
        COUNTER=$((COUNTER+1))

        if [[ $COUNTER -eq 2 ]]; then
          COMPLETED_COURSE=`ls -t /usr/local/blackboard/logs/content-exchange/BatchCxCmd* | tail -n 2| grep details.txt | cut -d'_' -f3- | awk -F'_details.txt' '{print $1}'`
          WORK_COUNTER_INT=$((WORK_COUNTER_INT+1))
          COUNTER=1
          echo $COMPLETED_COURSE > $IN_PROGRESS_FLAG_FILE
          # upload the flag file
          aws s3 cp $IN_PROGRESS_FLAG_FILE $S3_IN_PROGRESS_FILE --region $REGION  >> $S3_ACTIVITY_LOG
          # upload logs cause they can be deleted
          for log_file in `ls -t /usr/local/blackboard/logs/content-exchange/*${COMPLETED_COURSE}*`; do
            aws s3 mv $log_file $S3_ROOT_DIR/logs/
          done
          echo "Completed: $WORK_COUNTER_INT of $WORK_COUNTER_TOTAL"

        fi
      fi
    done
EOF

    echo "  Giving the right permissions to the monitor..."
    chmod +x ${WORK_LOCATION}/monitor_action_bb_logs.sh
    echo 4 > $IN_PROGRESS_FLAG_FILE

  fi

  # CREATION OF FEED FILE & AND UPLOAD IT FOR BACKUP
  # regular expression for any number

  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 4 ]] 2>/dev/null; then

    echo "  Creating Feed file or modifying it based on the duplicate/validity tests..."
    #feed format - course_id,/path/to/file.zip
    cat $COURSE_IDS > $FEED_FILE
    # upload feed file
    echo "  Backing up the new feed file..."
    aws s3 cp $FEED_FILE $S3_FEED --region $region

  # check if the flag is a course
  elif [[ ! $in_progress_flag =~ $re ]] 2>/dev/null; then
    echo "  In Progress flag is set to a course..."
    echo "  Downloading complete feed file that was uploaded in the previous section..."
    aws s3 cp $S3_FEED $FEED_FILE --region $region
    # create new feed file from that course onwards
    echo "  Deleting all courses until the one that was in progress to retry it..."
    sed -i '/'$in_progress_flag'/,$!d' $FEED_FILE
    echo "  Backing up the feed new feed file..."
    aws s3 cp $FEED_FILE $S3_FEED --region $region

  fi

   # and we let it run in the background
   echo "  Executing the monitor..."
   ${WORK_LOCATION}/monitor_action_bb_logs.sh ${ACTION} ${CLIENT_ID} ${WORK_LOCATION} ${S3_ROOT_DIR} ${region} > ${WORK_LOCATION}/${ACTION}_${CLIENT_ID}_monitor.log  &

   # clean the logs that will be monitored
   echo "  Deleting any course specific log and moving the content-exchange-log to a date backup ..."
   rm -rf /usr/local/blackboard/logs/content-exchange/BatchCxCmd_*
   if [ -f '/usr/local/blackboard/logs/content-exchange/content-exchange-log.txt' ]; then
     mv /usr/local/blackboard/logs/content-exchange/content-exchange-log.txt /usr/local/blackboard/logs/content-exchange/content-exchange-log-old.txt.${DATE}
   fi
   echo "  Executing the Restore/Import..."


   # command to execute
   start_time=`date +%s`
   sudo -u bbuser /usr/local/blackboard/apps/content-exchange/bin/batch_ImportExport.sh -f ${FEED_FILE} -l 1 -t ${ACTION} > ${WORK_LOCATION}/batch_${CLIENT_ID}.log
   end_time=`date +%s`
   # upload log file
   for log_file in `ls -t /usr/local/blackboard/logs/content-exchange/BatchCxCmd_*`; do
     aws s3 mv $log_file $S3_ROOT_DIR/logs/
   done
   echo "    Execution took `expr $end_time - $start_time` s."



elif [[ "$ACTION" == "archive" || "$ACTION" == "export" ]]; then
  echo ""
  echo "Starting Archive/Export Process"

  # we will skip step 0 = modify volume
  # we sill start in step 1
  # DOWNLOAD of files - in this case the feed file)
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 1 ]] 2>/dev/null; then
    echo "  Downloading feed file from S3..."
    aws s3 cp $S3_FEED $FEED_FILE --region $region
    sed  -i 's/$/,\/var\/tmp\/cloud_learn\/files\/,true,true,true/' $FEED_FILE
    if [ $? -eq 0 ]; then
      echo 2 > $IN_PROGRESS_FLAG_FILE
    else
      echo "No feed file exists in S3 and we need a Feed File to proceed. Exiting..."
      exit 1
    fi
  fi

  # TEST FEED FILE
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 2 ]] 2>/dev/null; then
    echo "  Testing feed file..."
    columns=`awk '{print NF}' $FEED_FILE | sort -nu | tail -n 1`
    if [[ $columns -gt 1 || $columns -eq 0 ]]; then
      echo "Feed file can only contain one column, with the course ids. Exiting..."
      exit 1
    else
      dos2unix $FEED_FILE
      echo 3 > $IN_PROGRESS_FLAG_FILE
    fi
  fi

  # CREATION OF MONITOR FILE
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 3 ]] 2>/dev/null; then
    echo "  Creating Monitor of zip creations..."

    cat > ${WORK_LOCATION}/monitor_action_files.sh <<- "EOF"
    #!/bin/bash
    ACTION=$1
    CLIENT_ID=$2
    WORK_LOCATION=$3
    S3_ROOT_DIR=$4
    REGION=$5

    S3_FILES="${S3_ROOT_DIR}/files/"
    S3_ACTIVITY_LOG="${WORK_LOCATION}/S3_${CLIENT_ID}_${ACTION}.log"
    COUNTER=0
    WORK_COUNTER_INT=0
    WORK_COUNTER_TOTAL=`wc -l $WORK_LOCATION/feed.txt | awk '{print $1}'`

    inotifywait -m /var/tmp/cloud_learn/files/ -e create | while read path action file; do

      COUNTER=$((COUNTER+1))
      if [[ $COUNTER -eq 2 ]]; then
        COMPLETED_FILE=`ls -t /var/tmp/cloud_learn/files/ |  tail -n 1`
        aws s3 mv /var/tmp/cloud_learn/files/${COMPLETED_FILE} ${S3_FILES} --region $REGION >> $S3_ACTIVITY_LOG
        COUNTER=1
        WORK_COUNTER_INT=$((WORK_COUNTER_INT+1))
        echo "Completed: $WORK_COUNTER_INT of $WORK_COUNTER_TOTAL"
      fi
    done
EOF

    echo "  Creating Monitor of logs creations..."
    cat > ${WORK_LOCATION}/monitor_action_bb_logs.sh <<- "EOF"
    #!/bin/bash
    ACTION=$1
    CLIENT_ID=$2
    WORK_LOCATION=$3
    S3_ROOT_DIR=$4
    REGION=$5
    COUNTER=0

    IN_PROGRESS_FLAG_FILE="${WORK_LOCATION}/in_progress.txt"
    S3_IN_PROGRESS_FILE="${S3_ROOT_DIR}/in_progress.txt"
    S3_ACTIVITY_LOG="${WORK_LOCATION}/S3_${CLIENT_ID}_${ACTION}.log"

    inotifywait -m /usr/local/blackboard/logs/content-exchange/ -e create | while read path action file; do

      if [[ "$file" =~ "BatchCxCmd" && "$file" =~ "details.txt" ]]; then
        COUNTER=$((COUNTER+1))

        if [[ $COUNTER -eq 2 ]]; then
          COMPLETED_COURSE=`ls -t /usr/local/blackboard/logs/content-exchange/BatchCxCmd* | tail -n 2| grep details.txt | cut -d'_' -f3- | awk -F'_details.txt' '{print $1}'`

          COUNTER=1
          echo $COMPLETED_COURSE > $IN_PROGRESS_FLAG_FILE
          # upload the flag file
          aws s3 cp $IN_PROGRESS_FLAG_FILE $S3_IN_PROGRESS_FILE --region $REGION  >> $S3_ACTIVITY_LOG
          # upload logs cause they can be deleted
          for log_file in `ls -t /usr/local/blackboard/logs/content-exchange/*${COMPLETED_COURSE}*`; do
            aws s3 mv $log_file $S3_ROOT_DIR/logs/
          done


        fi
      fi
    done
EOF
    echo "  Giving the right permissions to the monitors..."
    chmod +x ${WORK_LOCATION}/monitor_action_bb_logs.sh
    chmod +x ${WORK_LOCATION}/monitor_action_files.sh
    echo 4 > $IN_PROGRESS_FLAG_FILE
  fi


  # CREATION OF FEED FILE & AND UPLOAD IT FOR BACKUP
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 4 ]] 2>/dev/null; then
    echo "  Uploading modified feed file..."
    aws s3 cp $FEED_FILE $S3_FEED --region $region

  elif [[ ! $in_progress_flag =~ $re  || ${#in_progress_flag} -gt 1 ]] 2>/dev/null; then
    echo "  In Progress flag is set to a course..."
    echo "  Downloading complete feed file that was uploaded in the previous section..."
    aws s3 cp $S3_FEED $FEED_FILE --region $region
    # create new feed file from that course onwards
    echo "  Deleting all courses until the one that was in progress to retry it..."
    sed -i '/'$in_progress_flag'/,$!d' $FEED_FILE
    echo "  Backing up the feed new feed file..."
    aws s3 cp $FEED_FILE $S3_FEED --region $region
  fi


  echo "  Executing the monitors..."
  ${WORK_LOCATION}/monitor_action_bb_logs.sh ${ACTION} ${CLIENT_ID} ${WORK_LOCATION} ${S3_ROOT_DIR} ${region} > ${WORK_LOCATION}/${ACTION}_${CLIENT_ID}_monitor.log  &

  ${WORK_LOCATION}/monitor_action_files.sh ${ACTION} ${CLIENT_ID} ${WORK_LOCATION} ${S3_ROOT_DIR} ${region} > ${WORK_LOCATION}/${ACTION}_${CLIENT_ID}_monitor.log  &

  # clean the logs that will be monitored
  echo "  Deleting any course specific log and moving the content-exchange-log to a date backup ..."
  rm -rf /usr/local/blackboard/logs/content-exchange/BatchCxCmd_*
  if [ -f '/usr/local/blackboard/logs/content-exchange/content-exchange-log.txt' ]; then
    mv /usr/local/blackboard/logs/content-exchange/content-exchange-log.txt /usr/local/blackboard/logs/content-exchange/content-exchange-log-old.txt.${DATE}
  fi
  echo "  Executing the Archive/Export..."


  # command to execute
  start_time=`date +%s`
  sudo -u bbuser /usr/local/blackboard/apps/content-exchange/bin/batch_ImportExport.sh -f ${FEED_FILE} -l 1 -t ${ACTION} > ${WORK_LOCATION}/batch_${CLIENT_ID}.log
  end_time=`date +%s`
  echo "    Execution took `expr $end_time - $start_time` s."


fi



script_end_time=`date +%s`
echo ""
echo "TOTAL EXECUTION TIME: `expr $script_end_time - $script_start_time` s."
