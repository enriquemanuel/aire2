#!/bin/bash

ACTION=$1
CLIENT_ID=$2
S3_CURRENT_LOCATION=$3
CAPTAIN_JOB=$4
FEED_FILE_SET=$5 #boolean flag
RENAME_SET=$6 #boolean flag

# timer
script_start_time=`date +%s`

# SCRIPT VALIDATION CHECKS
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root";
  exit 1
fi

if [[ $# -ne 6 ]]; then
  echo "We need 6 parameters to proceed. Exiting..."
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
BB_LOG_DIR='/usr/local/blackboard/logs/content-exchange'
BROKEN_FILES="${WORK_LOCATION}/${CLIENT_ID}_${ACTION}_broken_files.txt"
COURSE_IDS="${WORK_LOCATION}/${CLIENT_ID}_${ACTION}_course_ids.txt"
DUPLICATES="${WORK_LOCATION}/${CLIENT_ID}_${ACTION}_duplicate_files.txt"

echo "Script started..."

## RUNTIME VARIABLES
region=`curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | awk -F'"' '/\"region\"/ { print $4 }'`
instance_id=`curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | awk -F'"' '/\"instanceId\"/ { print $4 }'`
volume_id=`aws ec2 describe-instances --instance-id $instance_id --region $region | jq '.Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId' | tr -d '"'`
volume_size=`aws ec2 describe-volumes --volume-ids $volume_id --region $region | jq '.Volumes[].Size'`
local_feed_file="no"


## S3 Variables
S3_ROOT_DIR="s3://learn-content-store/${CLIENT_ID}/${ACTION}/${CAPTAIN_JOB}"
S3_LOG_DIR="${S3_ROOT_DIR}/logs"
S3_INDIVIDUAL_LOGS="${S3_LOG_DIR}/individual"
S3_SUMMARY_LOGS="${S3_LOG_DIR}/summary"
S3_FILES="${S3_ROOT_DIR}/files/"
S3_FEED="${S3_ROOT_DIR}/feed.txt"
S3_IN_PROGRESS_FILE="${S3_ROOT_DIR}/in_progress.txt"
S3_ACTIVITY_LOG="${WORK_LOCATION}/S3_${CLIENT_ID}_${ACTION}.log"

# Pre checks before starting the script
if [[ "$ACTION" == "archive" || "$ACTION" == "export" ]]; then
  # check if there is an in progress file
  echo "Checking if there is an in progress file..."
  aws s3 cp $S3_IN_PROGRESS_FILE $IN_PROGRESS_FLAG_FILE > /dev/null 2>&1
  if [ $? -eq 0 ]; then
    # there is an in progress file
    echo "  There is one in progress file... setting correct values."
    in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
    echo "    In Progress flag: $in_progress_flag"
    # if there is a directory
    # lets change the feed file based on the in progress flag
    if [[ ! $in_progress_flag =~ $re || ${#in_progress_flag} -gt 1 ]] 2>/dev/null; then
      # if the in progress flag is a course or not a step then
      aws s3 cp $S3_FEED $FEED_FILE --region $region >> $S3_ACTIVITY_LOG
      sed -i '/'$in_progress_flag'/,$!d' $FEED_FILE
      aws s3 cp $FEED_FILE $S3_FEED --region $region >> $S3_ACTIVITY_LOG
    elif [[ $in_progress_flag -eq 9 ]]; then
      only_summary="yes"
    fi
  fi
  # there was no in progress flag
  # we dont care if there was a working directory lets try to move it
  mv $WORK_LOCATION ${WORK_LOCATION}_backup 2>/dev/null
  # then create it
  mkdir -p $WORK_LOCATION
  # finally set the flag accordingly.
  if [[ $only_summary == "yes" ]]; then
    echo 9 > $IN_PROGRESS_FLAG_FILE
  else
    echo 1 > $IN_PROGRESS_FLAG_FILE
  fi


elif [[ "$ACTION" == "import" || "$ACTION" == "restore" ]]; then
  echo "Checking if there is an in progress file..."
  # check if there is an in progress file
  aws s3 cp $S3_IN_PROGRESS_FILE $IN_PROGRESS_FLAG_FILE > /dev/null 2>&1
  if [ $? -eq 0 ]; then
    # there was an in progress file
    echo "  There is one in progress file... setting correct values."
    in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
    echo "    In Progress flag: $in_progress_flag"
    # lets check if there is a directory with contents
    if [[ ! $in_progress_flag =~ $re || ${#in_progress_flag} -gt 1 ]] 2>/dev/null; then
      if [[ ! $in_progress_flag == "restore" ]]; then
        FEED_FILE_SET="yes"
        # if the flag is a course or not a step
        aws s3 cp $S3_FEED $FEED_FILE --region $region >> $S3_ACTIVITY_LOG
        sed -i '/'$in_progress_flag'/,$!d' $FEED_FILE
        feed_line_count=`wc -l ${FEED_FILE} | awk '{print $1}'`
        echo "New Feed file line count: $feed_line_count"
        cat $FEED_FILE > $COURSE_IDS
        local_feed_file="yes"
        echo "here"
        aws s3 cp $FEED_FILE $S3_FEED --region $region >> $S3_ACTIVITY_LOG
      fi
    elif [[ $in_progress_flag -eq 9 ]]; then
        only_summary="yes"
    fi
  fi
  # there was no in progress flag
  # we dont care if there was a working directory lets try to move it
  rm -rf ${WORK_LOCATION}_backup 2>/dev/null
  mv $WORK_LOCATION ${WORK_LOCATION}_backup 2>/dev/null
  # then create it
  mkdir -p $WORK_LOCATION
  # finally set the flag accordingly.
  if [[ $only_summary == "yes" ]]; then
    echo 9 > $IN_PROGRESS_FLAG_FILE
  else
    echo 0 > $IN_PROGRESS_FLAG_FILE
  fi
fi

echo "Completed checking... Follow the log @ ${ACTIVITY_LOG}"

echo "Creating required folders..." >> ${ACTIVITY_LOG}
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

# move the monitor scripts



# function in case it gets exited (stopped) for whatever reason
function trap2exit (){

  echo "Something killed the script so lets save the progress..." >> ${ACTIVITY_LOG}
  aws s3 cp $IN_PROGRESS_FLAG_FILE $S3_IN_PROGRESS_FILE --region $region >> $S3_ACTIVITY_LOG
  aws s3 cp $FEED_FILE $S3_FEED --region $region >> $S3_ACTIVITY_LOG
  for log_file in `ls ${BB_LOG_DIR}/content-exchange-log* | awk -F'/' '{print $7}'`; do
    if [[ ${log_file: -3} == "txt" ]]; then
      aws s3 cp $BB_LOG_DIR/$log_file $S3_SUMMARY_LOGS/${log_file}.${DATE} --region $region >> $S3_ACTIVITY_LOG
    else
      aws s3 cp $BB_LOG_DIR/$log_file $S3_SUMMARY_LOGS/ --region $region >> $S3_ACTIVITY_LOG
    fi
  done
  aws s3 cp $S3_ACTIVITY_LOG $S3_ROOT_DIR/ --region $region >> $S3_ACTIVITY_LOG

  end_time=`date +%s`
  echo "    Script took `expr $end_time - $start_time` s." >> ${ACTIVITY_LOG}
  exit 0;
}

# trap if if we kill it
trap trap2exit SIGHUP SIGINT SIGTERM

# add jq to the ubuntu repo 16.04
if [ "$(grep -c 'deb http://us.archive.ubuntu.com/ubuntu xenial main universe'   /etc/apt/sources.list)" -eq 0 ]; then
  echo "deb http://us.archive.ubuntu.com/ubuntu xenial main universe" >> /etc/apt/sources.list
fi

# update the repos and install dependencies
echo "Installing dependencies..." >> ${ACTIVITY_LOG}
#sudo apt-get update > /dev/null 2>&1
#sudo apt-get install -y inotify-tools dos2unix jq > /dev/null 2>&1
#sudo pip install pip install --upgrade --user awscli > /dev/null 2>&1

echo "Killing old monitors..." >> ${ACTIVITY_LOG}
sudo killall inotifywait > /dev/null 2>&1

# modify the heap for the archive process to have 12G
# if the instance is bigger, this can be customizable
if [ "$(grep -c '$OPTS -Xmx13g'   /usr/local/blackboard/apps/content-exchange/bin/batch_ImportExport.sh)" -eq 0 ]; then
  sed -i '/OPTS=""/a OPTS="$OPTS -Xmx13g"' /usr/local/blackboard/apps/content-exchange/bin/batch_ImportExport.sh
fi


if [[ "$ACTION" == "import" || "$ACTION" == "restore" ]]; then
  echo "" >> ${ACTIVITY_LOG}
  echo "Starting Import/Restore Process" >> ${ACTIVITY_LOG}

  # START OF THE PROCESS AND RESIZE OF THE VOLUME
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 0 ]] 2>/dev/null; then


    # get directory size in s3
    # Bytes/MiB/KiB/GiB/TiB/PiB/EiB types
    echo "  Reading the required volume size..." >> ${ACTIVITY_LOG}
    files_size=`aws s3 ls ${S3_CURRENT_LOCATION} --summarize --human-readable --region $region | tail -n1 | awk '{print $3,$4}'`
    echo "here"
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
      echo "    Not accepting Tera / Penta / Exbi - Bytes at this time.. exiting" >> ${ACTIVITY_LOG}
      exit 1
    fi

    echo "  Modifying the volume size..." >> ${ACTIVITY_LOG}
    # resize volume
    if [[ "$volume_size" == "$required_size"  ]]; then
      echo "    Volume is the required size." >> ${ACTIVITY_LOG}
    else
      aws ec2 modify-volume --volume-id $volume_id --size $required_size --region $region
      if [ $? -ne 0 ] ; then
        echo "    There was a problem modifying the volume. Exiting..." >> ${ACTIVITY_LOG}
        exit 1
      fi
      echo "    Modification Complete"
    fi

    # set in progress flag
    echo 1 > $IN_PROGRESS_FLAG_FILE
    aws s3 cp $IN_PROGRESS_FLAG_FILE $S3_IN_PROGRESS_FILE --region $region >> $S3_ACTIVITY_LOG
  fi


  # DOWNLOAD OF FILES
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 1 ]] 2>/dev/null; then
    echo "  Downloading Files from S3..." >> ${ACTIVITY_LOG}
    # download files
    start_time=`date +%s`
    aws s3 sync ${S3_CURRENT_LOCATION} ${WORK_LOCATION_FILES} --region $region >> $S3_ACTIVITY_LOG
    end_time=`date +%s`
    echo "    Download took `expr $end_time - $start_time` s." >> ${ACTIVITY_LOG}
    # set in progress flag
    echo 2 > $IN_PROGRESS_FLAG_FILE
    aws s3 cp $IN_PROGRESS_FLAG_FILE $S3_IN_PROGRESS_FILE --region $region >> $S3_ACTIVITY_LOG
  fi

  # CHECK FOR DUPLICATES AND BROKEN FILES
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 2 ]] 2>/dev/null; then

    # if no feed file was provided
    if [[ "$FEED_FILE_SET" == "no" ]]; then
      # test them / check for:
      echo "  No Client Feed file, creating one from the files..." >> ${ACTIVITY_LOG}
      echo "  Looking for broken or corrupted .zip files..." >> ${ACTIVITY_LOG}

      # courses that come from other LMS get "imported not restore"
      # only courses coming from Bb have the .bb-package-info
      ## bad zip files
      for i in `ls $WORK_LOCATION_FILES/*.zip`; do
        unzip -t $i &> /dev/null
        if [ $? -ne 0 ] ; then
          echo "    Course $i is broken..." >> ${ACTIVITY_LOG}
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
      echo "  Looking for duplicate files..." >> ${ACTIVITY_LOG}
      for i in `cat $COURSE_IDS | awk '{print $2}' | sort | uniq -d`; do
        grep $i $COURSE_IDS
      done > $DUPLICATES

      echo 3 > $IN_PROGRESS_FLAG_FILE
      aws s3 cp $IN_PROGRESS_FLAG_FILE $S3_IN_PROGRESS_FILE --region $region >> $S3_ACTIVITY_LOG

    # user provided feed file
    elif [[ "$FEED_FILE_SET" == "yes" ]]; then
      echo "  Downloading client provided feed file..." >> ${ACTIVITY_LOG}
      aws s3 cp $S3_FEED $FEED_FILE --region $region >> ${S3_ACTIVITY_LOG}
      echo "  Client Provided feed file" >> ${ACTIVITY_LOG}
      echo "  Looking for broken or corrupted .zip files..." >> ${ACTIVITY_LOG}
      columns=`awk -F',' '{print NF}' $FEED_FILE | sort -nu | tail -n 1`

      if [[ "$RENAME_SET" == "yes" ]]; then
        echo "  We don't accept renaming when providing a feed file." >> ${ACTIVITY_LOG}
        echo "  Please provide a correct feed file with the names you want." >> ${ACTIVITY_LOG}
        exit 1
      fi

      # feed file only contains course id
      if [[ $columns -eq 1 ]]; then
      # only test files specified in the feed file
        for course_id in `cat $FEED_FILE`; do
          file=`ls $WORK_LOCATION_FILES/ | grep $course_id | head -n1`
          unzip -t $WORK_LOCATION_FILES/$file &> /dev/null
          if [ $? -ne 0 ] ; then
            echo "    Course $course_id is broken..." >> ${ACTIVITY_LOG}
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
        if [[ "$local_feed_file" == "yes" ]]; then
          cat $FEED_FILE > $COURSE_IDS
        elif [[ "$local_feed_file" == "no" ]]; then
          for zip_file in `cat $FEED_FILE | awk '{print $2}'`; do

            if [[ "${zip_file:0:1}" == "/" ]]; then
              # check if its a local path
              if [[ ! "${zip_file:0:26}" == "${WORK_LOCATION_FILES}" ]]; then
                echo "  We don't accept paths in the second column of the feed file. Exiting..."
                exit 1
              fi
            elif [[ ! ${zip_file:0:1} =~ $re && ! "${zip_file:0:1}" == "/"  ]]; then
              file=`ls $WORK_LOCATION_FILES/ | grep $zip_file | head -n1`
              diff_course_id=`grep $zip_file $FEED_FILE | awk '{print $1}'`
              unzip -t $WORK_LOCATION_FILES/$zip_file &> /dev/null
              if [ $? -ne 0 ] ; then
                echo "    Course $zip_file is broken..." >> ${ACTIVITY_LOG}
                echo "$zip_file" >> $BROKEN_FILES
              else
                echo "$diff_course_id $WORK_LOCATION_FILES/$zip_file" >> $COURSE_IDS
              fi
            fi
          done
        # some other weird format feed file
        else
          echo "    Incorrect feed file type..." >> ${ACTIVITY_LOG}
          exit 1
        fi

        echo "  Looking for duplicate files..." >> ${ACTIVITY_LOG}
        for i in `cat $COURSE_IDS | awk '{print $1}' | sort | uniq -d`; do
          grep $i $COURSE_IDS
        done > $DUPLICATES

      fi

      echo 3 > $IN_PROGRESS_FLAG_FILE
      aws s3 cp $IN_PROGRESS_FLAG_FILE $S3_IN_PROGRESS_FILE --region $region >> $S3_ACTIVITY_LOG
    fi
  fi



  # CREATION OF MONITOR FILE
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 3 ]] 2>/dev/null; then
    cp *monitor*.sh ${WORK_LOCATION}/
    echo "  Giving the right permissions to the monitor..." >> ${ACTIVITY_LOG}
    chmod +x ${WORK_LOCATION}/restore-import_monitor_bb_logs.sh

    echo 4 > $IN_PROGRESS_FLAG_FILE
    aws s3 cp $IN_PROGRESS_FLAG_FILE $S3_IN_PROGRESS_FILE --region $region >> $S3_ACTIVITY_LOG
  fi

  # CREATION OF FEED FILE & AND UPLOAD IT FOR BACKUP
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 4 ]] 2>/dev/null; then
    echo "  Creating Feed file or modifying it based on the duplicate/validity tests..." >> ${ACTIVITY_LOG}
    #feed format - course_id,/path/to/file.zip
    cat $COURSE_IDS > $FEED_FILE
    # upload feed file
    echo "  Backing up the new feed file..." >> $ACTIVITY_LOG
    aws s3 cp $FEED_FILE $S3_FEED --region $region >> $S3_ACTIVITY_LOG
    echo ${ACTION} > $IN_PROGRESS_FLAG_FILE
    aws s3 cp $IN_PROGRESS_FLAG_FILE $S3_IN_PROGRESS_FILE --region $region >> $S3_ACTIVITY_LOG
  fi

  # EXECUTION
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ ! $in_progress_flag =~ $re || ${#in_progress_flag} -gt 1 ]] 2>/dev/null; then
    echo "  In Progress flag is set to a course..." >> ${ACTIVITY_LOG}

    # and we let it run in the background
    echo "  Executing the monitor..." >> ${ACTIVITY_LOG}

    ${WORK_LOCATION}/restore-import_monitor_bb_logs.sh ${ACTION} ${CLIENT_ID} ${WORK_LOCATION} ${S3_ROOT_DIR} ${region} ${S3_CURRENT_LOCATION} >> ${ACTIVITY_LOG}  &

    # clean the logs that will be monitored
    echo "  Deleting any course specific log and moving the content-exchange-log to a date backup ..." >> ${ACTIVITY_LOG}
    rm -rf /usr/local/blackboard/logs/content-exchange/BatchCxCmd_*
    if [ -f '/usr/local/blackboard/logs/content-exchange/content-exchange-log.txt' ]; then
      mv /usr/local/blackboard/logs/content-exchange/content-exchange-log.txt /usr/local/blackboard/logs/content-exchange/content-exchange-log-old.txt.${DATE}
    fi
    echo "  Executing the Restore/Import..." >> ${ACTIVITY_LOG}

    # command to execute
    start_time=`date +%s`
    sudo -u bbuser /usr/local/blackboard/apps/content-exchange/bin/batch_ImportExport.sh -f ${FEED_FILE} -l 1 -t ${ACTION} > ${WORK_LOCATION}/batch_${CLIENT_ID}.log

    sleep 10

    file_to_move=`tail -n1 ${FEED_FILE} | awk -F'/' '{print $6}'`
    if [[ ${S3_CURRENT_LOCATION: -1} == "/" ]]; then
      S3_CURRENT_LOCATION=${S3_CURRENT_LOCATION:0:-1}
    fi
    aws s3 mv $S3_CURRENT_LOCATION/$file_to_move $S3_ROOT_DIR/completed/$file_to_move  --region $region --dryrun

    feed_line_count=`wc -l ${FEED_FILE} | awk '{print $1}'`
    echo "    Completed: $feed_line_count of $feed_line_count " >> ${ACTIVITY_LOG}
    echo "  Finish Execution."
    end_time=`date +%s`
    echo "    ${ACTION} took `expr $end_time - $start_time` s." >> ${ACTIVITY_LOG}

    # upload the last log file
    for log_file in `ls -t ${BB_LOG_DIR}/BatchCxCmd_*`; do
      aws s3 mv $log_file $S3_INDIVIDUAL_LOGS/ --region $region >> $S3_ACTIVITY_LOG
    done

    # we need to upload the complete log file if this server goes down
    for summary_log in `ls ${BB_LOG_DIR}/content-exchange-log* | awk -F'/' '{print $7}'`; do
      aws s3 cp ${BB_LOG_DIR}/$summary_log $S3_SUMMARY_LOGS/$summary_log-${DATE} --region $region >> $S3_ACTIVITY_LOG
    done

    echo 9 > $IN_PROGRESS_FLAG_FILE
    aws s3 cp $IN_PROGRESS_FLAG_FILE $S3_IN_PROGRESS_FILE --region $region >> $S3_ACTIVITY_LOG
  fi

  # summmary
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 9 ]] 2>/dev/null; then
    echo "  Checking for errors and fatals in the failed logs..." >> ${ACTIVITY_LOG}
    # SUMMARY
    # if there were files there move them to something else
    for summary_log in `ls ${BB_LOG_DIR}/content-exchange-log*`; do
      name=`echo $summary_log | awk -F'/' '{print $7}'`
      mv $summary_log ${BB_LOG_DIR}/cloud_old-$name
    done
    # download the files that were uploaded just in case
    aws s3 sync $S3_SUMMARY_LOGS $BB_LOG_DIR --region $region >> $S3_ACTIVITY_LOG

    # then lets process all the files
    for summary_log in `ls ${BB_LOG_DIR}/content-exchange-log* | awk -F'/' '{print $7}'`; do
      # check the extension of file, if gz do zgrep, else do below
      if [[ ${summary_log: -2} == "gz" ]]; then
        # check if there were any fatal
        if [[ "$(zgrep -m1 -c 'Fatal' ${BB_LOG_DIR}/${summary_log})" -gt 0 ]]; then
         # if yes then lets output to the log and find them
         # get the failed courses.
         echo "Summary File: ${summary_log}">> ${ACTIVITY_LOG}
         echo "Failed courses in this batch..." >>${ACTIVITY_LOG}
         echo >> ${ACTIVITY_LOG}

         for fatal_course in `zgrep -B5 -A1 'Fatal' ${BB_LOG_DIR}/${summary_log} | grep "Executed" | awk '{print $8}' | uniq`; do
            echo "Course failed "$fatal_course" with log:" >> ${FAILED_LOG};
            zgrep -m1 -A6 "Executed ${ACTION} for ${fatal_course}" ${BB_LOG_DIR}/${summary_log} >> ${FAILED_LOG};
            echo >> ${FAILED_LOG}; echo >> ${FAILED_LOG};
          done

          # lets print the failed ones in the complete log
          cat ${FAILED_LOG} >> ${ACTIVITY_LOG}
          echo >> ${ACTIVITY_LOG}
        fi
      else

        # check if there were any fatal
        if [[ "$(grep -m1 -c 'Fatal' ${BB_LOG_DIR}/${summary_log})" -gt 0 ]]; then
          # if yes then lets output to the log and find them
          # get the failed courses.
          echo >> ${ACTIVITY_LOG}
          echo "Failed courses in this batch..." >>${ACTIVITY_LOG}
          echo >> ${ACTIVITY_LOG}


          for fatal_course in `grep -B5 -A1 'Fatal' ${BB_LOG_DIR}/${summary_log} | grep "Executed" | awk '{print $8}' | uniq`; do

            echo "Course failed "$fatal_course" with log:" >> ${FAILED_LOG};
            grep -m1 -A6 "Executed ${ACTION} for ${fatal_course}" ${summary_log} >> ${FAILED_LOG};
            echo >> ${FAILED_LOG}; echo >> ${FAILED_LOG};
          done

          # lets print the failed ones in the complete log
          cat ${FAILED_LOG} >> ${ACTIVITY_LOG}
          echo >> ${ACTIVITY_LOG}
        fi
      fi

      # we need to upload the complete log file if this server goes down
      aws s3 cp ${BB_LOG_DIR}/${summary_log} $S3_SUMMARY_LOGS/${summary_log}-.${DATE} --region $region >> $S3_ACTIVITY_LOG
    done
    if [[ ! -f $FAILED_LOG ]]; then
      echo "    There were no fatals in this execution." >> ${ACTIVITY_LOG}
    fi
  fi


elif [[ "$ACTION" == "archive" || "$ACTION" == "export" ]]; then
  echo "" >> ${ACTIVITY_LOG}
  echo "Starting Archive/Export Process" >> ${ACTIVITY_LOG}

  # we will skip step 0 = modify volume
  # we sill start in step 1
  # DOWNLOAD of files - in this case the feed file)
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 1 ]] 2>/dev/null; then
    echo "  Downloading feed file from S3..." >> ${ACTIVITY_LOG}
    aws s3 cp $S3_FEED $FEED_FILE --region $region >> ${S3_ACTIVITY_LOG}
    if [ $? -eq 0 ]; then
      echo 2 > $IN_PROGRESS_FLAG_FILE
    else
      echo "No feed file exists in S3 and we need a Feed File to proceed. Exiting..." >> ${ACTIVITY_LOG}
      exit 1
    fi
    columns=`awk -F',' '{print NF}' $FEED_FILE | sort -nu | tail -n 1`
    if [[ $columns -gt 1 || $columns -eq 0 ]]; then
      echo "Feed file can only contain one column, with the course ids. Exiting..." >> ${ACTIVITY_LOG}
      exit 1
    else
      sed  -i 's/$/,\/var\/tmp\/cloud_learn\/files\/,true,true,true/' $FEED_FILE
    fi
  fi

  # TEST FEED FILE
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 2 ]] 2>/dev/null; then
    echo "  Testing feed file..." >> ${ACTIVITY_LOG}
      dos2unix $FEED_FILE 2>/dev/null
      echo 3 > $IN_PROGRESS_FLAG_FILE
  fi

  # CREATION OF MONITOR FILE
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 3 ]] 2>/dev/null; then
    echo "  Giving the right permissions to the monitors..." >> ${ACTIVITY_LOG}

    chmod +x ${WORK_LOCATION}/archive-export_monitor_bb_logs.sh
    chmod +x ${WORK_LOCATION}/archive-export_monitor_zip_files.sh
    echo 4 > $IN_PROGRESS_FLAG_FILE
  fi

  # CREATION OF FEED FILE & AND UPLOAD IT FOR BACKUP
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 4 ]] 2>/dev/null; then
    echo "  Uploading modified feed file..." >> ${ACTIVITY_LOG}
    aws s3 cp $FEED_FILE $S3_FEED --region $region >> ${S3_ACTIVITY_LOG}
    echo $ACTION > $IN_PROGRESS_FLAG_FILE
  fi

  # execution
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ ! $in_progress_flag =~ $re  || ${#in_progress_flag} -gt 1 ]] 2>/dev/null; then
    echo "  In Progress flag is set to a course..." >> ${ACTIVITY_LOG}

    echo "  Executing the monitors..." >> ${ACTIVITY_LOG}
    ${WORK_LOCATION}/archive-export_monitor_bb_logs.sh ${ACTION} ${CLIENT_ID} ${WORK_LOCATION} ${S3_ROOT_DIR} ${region} >> ${ACTIVITY_LOG}  & 2>/dev/null
    ${WORK_LOCATION}/archive-export_monitor_zip_files.sh ${ACTION} ${CLIENT_ID} ${WORK_LOCATION} ${S3_ROOT_DIR} ${region} >> ${ACTIVITY_LOG}  & 2>/dev/null


    # clean the logs that will be monitored
    echo "  Deleting any course specific log and moving the content-exchange-log to a date backup ..." >> ${ACTIVITY_LOG}
    rm -rf /usr/local/blackboard/logs/content-exchange/BatchCxCmd_*
    if [ -f '/usr/local/blackboard/logs/content-exchange/content-exchange-log.txt' ]; then
      mv /usr/local/blackboard/logs/content-exchange/content-exchange-log.txt /usr/local/blackboard/logs/content-exchange/content-exchange-log-old.txt.${DATE}
    fi
    echo "  Executing the Archive/Export..." >> ${ACTIVITY_LOG}

    # command to execute
    start_time=`date +%s`
    sudo -u bbuser /usr/local/blackboard/apps/content-exchange/bin/batch_ImportExport.sh -f ${FEED_FILE} -l 1 -t ${ACTION} > ${WORK_LOCATION}/batch_${CLIENT_ID}.log

    feed_line_count=`wc -l ${FEED_FILE} | awk '{print $1}'`
    echo "    Completed: $feed_line_count of $feed_line_count " >> ${ACTIVITY_LOG}
    echo "  Finish Execution."

    end_time=`date +%s`
    echo "    ${ACTION} took `expr $end_time - $start_time` s." >> ${ACTIVITY_LOG}

    # we need to upload the last file that is not being uploaded
    for zip_file in `ls ${WORK_LOCATION}/files/*.zip`; do
      aws s3 mv ${zip_file} ${S3_FILES} --region $region >> $S3_ACTIVITY_LOG
    done

    # we need to upload the last logs that were not being uploaded
    for log_file in `ls -t ${BB_LOG_DIR}/BatchCxCmd*`; do
      aws s3 mv ${log_file} $S3_INDIVIDUAL_LOGS/ --region $region >> $S3_ACTIVITY_LOG
    done

    # upload summary logs
    for summary_log in `ls ${BB_LOG_DIR}/content-exchange-log* | awk -F'/' '{print $7}'`; do
      aws s3 cp ${BB_LOG_DIR}/$summary_log $S3_SUMMARY_LOGS/ --region $region >> $S3_ACTIVITY_LOG
    done
    echo 9 > $IN_PROGRESS_FLAG_FILE

  fi

  # summmary
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 9 ]] 2>/dev/null; then
    echo "  Checking for errors and fatals in the failed logs..." >> ${ACTIVITY_LOG}
    # SUMMARY
    for summary_log in `ls ${BB_LOG_DIR}/content-exchange-log*`; do
      name=`echo $summary_log | awk -F'/' '{print $7}'`
      mv $summary_log ${BB_LOG_DIR}/cloud_old-$name
    done
    # download the files that were uploaded just in case
    aws s3 sync $S3_SUMMARY_LOGS $BB_LOG_DIR >> $S3_ACTIVITY_LOG

    # then lets process all the files
    for summary_log in `ls ${BB_LOG_DIR}/content-exchange-log* | awk -F'/' '{print $7}'`; do
      # check the extension of file, if gz do zgrep, else do below
      if [[ ${summary_log: -2} == "gz" ]]; then
        # check if there were any fatal
        if [[ "$(zgrep -m1 -c 'Fatal' ${BB_LOG_DIR}/${summary_log})" -gt 0 ]]; then
         # if yes then lets output to the log and find them
         # get the failed courses.
         echo "Summary File: ${summary_log}">> ${ACTIVITY_LOG}
         echo "Failed courses in this batch..." >>${ACTIVITY_LOG}
         echo >> ${ACTIVITY_LOG}

         for fatal_course in `zgrep -B5 -A1 'Fatal' ${BB_LOG_DIR}/${summary_log} | grep "Executed" | awk '{print $8}' | uniq`; do
            echo "Course failed "$fatal_course" with log:" >> ${FAILED_LOG};
            zgrep -m1 -A6 "Executed ${ACTION} for ${fatal_course}" ${BB_LOG_DIR}/${summary_log} >> ${FAILED_LOG};
            echo >> ${FAILED_LOG}; echo >> ${FAILED_LOG};
          done

          # lets print the failed ones in the complete log
          cat ${FAILED_LOG} >> ${ACTIVITY_LOG}
          echo >> ${ACTIVITY_LOG}
        fi
      else

        # check if there were any fatal
        if [[ "$(grep -m1 -c 'Fatal' ${BB_LOG_DIR}/${summary_log})" -gt 0 ]]; then
          # if yes then lets output to the log and find them
          # get the failed courses.
          echo >> ${ACTIVITY_LOG}
          echo "Failed courses in this batch..." >>${ACTIVITY_LOG}
          echo >> ${ACTIVITY_LOG}


          for fatal_course in `grep -B5 -A1 'Fatal' ${BB_LOG_DIR}/${summary_log} | grep "Executed" | awk '{print $8}' | uniq`; do
            echo ${action}
            echo $fatal_course
            echo "Course failed "$fatal_course" with log:" >> ${FAILED_LOG};
            grep -m1 -A6 "Executed ${ACTION} for ${fatal_course}" ${BB_LOG_DIR}/${summary_log} >> ${FAILED_LOG};
            echo >> ${FAILED_LOG}; echo >> ${FAILED_LOG};
          done

          # lets print the failed ones in the complete log
          cat ${FAILED_LOG} >> ${ACTIVITY_LOG}
          echo >> ${ACTIVITY_LOG}
        fi
      fi

      # we need to upload the complete log file if this server goes down
      #aws s3 cp ${BB_LOG_DIR}/${summary_log} $S3_SUMMARY_LOGS/${summary_log}-.${DATE} --region $region >> $S3_ACTIVITY_LOG
    done

    if [[ ! -f $FAILED_LOG ]]; then
      echo "    There were no fatals in this execution." >> ${ACTIVITY_LOG}
    fi

  fi

fi


script_end_time=`date +%s`
echo "" >> ${ACTIVITY_LOG}
echo "TOTAL EXECUTION TIME: `expr $script_end_time - $script_start_time` s." >> ${ACTIVITY_LOG}

echo "Script completed. Please review log at @ ${ACTIVITY_LOG}"
echo ""
# display the log
cat ${ACTIVITY_LOG}
