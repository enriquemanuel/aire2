#!/bin/bash

ACTION=$1
CLIENT_ID=$2
S3_ROOT_DIR_PARAM=$3
CAPTAIN_JOB=`date +%s`
FEED_FILE_SET=$4 #boolean flag
RENAME_SET=$5 #boolean flag
S3_CURRENT_LOCATION=$6
AWS_PROFILE=$7		# AWS Cred

echo ""
echo "Action: $ACTION"
echo "Client ID = $CLIENT_ID"
echo "S3_ROOT_DIR: $S3_ROOT_DIR_PARAM"
echo "FEED_FILE_SET: $FEED_FILE_SET"
echo "RENAME_SET: $RENAME_SET"
echo "S3_CURRENT_LOCATION: $S3_CURRENT_LOCATION"
echo "AWS_PROFILE: $AWS_PROFILE"
echo ""



# timer
script_start_time=`date +%s`

# SCRIPT VALIDATION CHECKS
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root";
  echo ""
  exit 1
fi

if [[ $# -ne 7 ]]; then
  echo "We need 7 parameters to proceed. Exiting..."
  echo ""
  exit 1
fi

if [[ ${S3_CURRENT_LOCATION: -1} == "/" ]]; then
  S3_CURRENT_LOCATION=${S3_CURRENT_LOCATION:0:-1}
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

echo ""
echo "Script started..."

## RUNTIME VARIABLES
region=`curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | awk -F'"' '/\"region\"/ { print $4 }'`
instance_id=`curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | awk -F'"' '/\"instanceId\"/ { print $4 }'`
volume_id=`aws ec2 describe-instances --instance-id $instance_id --region $region | jq '.Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId' | tr -d '"'`
volume_size=`aws ec2 describe-volumes --volume-ids $volume_id --region $region | jq '.Volumes[].Size'`
local_feed_file="no"


## S3 Variables
S3_FEED="${S3_ROOT_DIR_PARAM}/${CLIENT_ID}/${ACTION}/feed.txt"
S3_ROOT_DIR="${S3_ROOT_DIR_PARAM}/AIRE/${CLIENT_ID}/${ACTION}/${CAPTAIN_JOB}"
S3_LOG_DIR="${S3_ROOT_DIR}/logs"
S3_INDIVIDUAL_LOGS="${S3_LOG_DIR}/individual"
S3_SUMMARY_LOGS="${S3_LOG_DIR}/summary"
S3_FILES="${S3_ROOT_DIR}/files/"
files_to_download=""


echo "Individual Logs can be found: ${S3_ROOT_DIR}/logs/individual/"
echo "Summary Logs can be found: ${S3_ROOT_DIR}/logs/summary/"
echo ""


S3_IN_PROGRESS_FILE="${S3_ROOT_DIR}/in_progress.txt"
S3_ACTIVITY_LOG="${WORK_LOCATION}/S3_${CLIENT_ID}_${ACTION}.log"

echo ""
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
  rm -rf  $WORK_LOCATION/*
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
  rm -rf ${WORK_LOCATION}/*
  mkdir -p $WORK_LOCATION

  # finally set the flag accordingly.
  if [[ $only_summary == "yes" ]]; then
    echo 9 > $IN_PROGRESS_FLAG_FILE
  else
    echo 0 > $IN_PROGRESS_FLAG_FILE
  fi
fi

echo "Completed checking..."

echo "Creating required folders..."
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

# function in case it gets exited (stopped) for whatever reason
function trap2exit (){

  echo "Stopping all scripts..."
  aws s3 cp $IN_PROGRESS_FLAG_FILE $S3_IN_PROGRESS_FILE --region $region >> $S3_ACTIVITY_LOG
  aws s3 cp ${WORK_LOCATION}/batch_${CLIENT_ID}.log $S3_LOG_DIR/batch_${CLIENT_ID}.log.${DATE} --region $region >> $S3_ACTIVITY_LOG
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
  echo "    Script took `expr $end_time - $start_time` s."
  exit 0;
}

# trap if if we kill it
trap trap2exit SIGHUP SIGINT SIGTERM

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


    # get directory size in s3
    # Bytes/MiB/KiB/GiB/TiB/PiB/EiB types
    echo "  Reading the required volume size..."
    files_size=`aws s3 ls "${S3_CURRENT_LOCATION}/" --summarize --human-readable --region $region | tail -n1 | awk '{print $3,$4}'` > /dev/null 2>&1
    files_size_type=`echo $files_size | awk '{print $2}'`
    files_size_count=`echo $files_size | awk '{print $1}'`

    if [[ "$files_size_count" == "0" ]] 2>/dev/null; then
      echo "  File size is 0. Maybe wrong path? ... exiting"
      echo ""
      exit 1
    fi

    files_size_count_rounded=`echo "($files_size_count+0.5)/1" | bc`

    if [[ "$files_size_type" == "GiB" ]]; then
      required_size=$((100 + $files_size_count_rounded))
    elif [[ "$files_size_type" == "MiB" ]]; then
      required_size=100
    else
      echo "    Not accepting Tera / Penta / Exbi - Bytes at this time.. exiting"
      echo ""
      exit 1
    fi

    # resize volume
    if [[ "$volume_size" == "$required_size"  ]]; then
      echo "    Volume is the required size."
    else
      echo "    Volume is not the correct size. Exiting..."
      exit 1
    fi


    # set in progress flag
    echo 1 > $IN_PROGRESS_FLAG_FILE
    aws s3 cp $IN_PROGRESS_FLAG_FILE $S3_IN_PROGRESS_FILE --region $region >> $S3_ACTIVITY_LOG
  fi

  # DOWNLOAD OF FILES
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 1 ]] 2>/dev/null; then

    echo "  Downloading ${files_size} from S3..."

    # download files
    start_time=`date +%s`
    aws s3 sync "${S3_CURRENT_LOCATION}" ${WORK_LOCATION_FILES} --region $region >> $S3_ACTIVITY_LOG
    end_time=`date +%s`
    echo "    Download took `expr $end_time - $start_time` s."
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
      echo "  No Client Feed file, creating one from the files..."
      echo "  Looking for broken or corrupted .zip files..."

      # courses that come from other LMS get "imported not restore"
      # only courses coming from Bb have the .bb-package-info
      ## bad zip files
      for i in `ls $WORK_LOCATION_FILES/*.zip`; do
        unzip -t $i &> /dev/null
        if [ $? -ne 0 ] ; then
          temp_file=`echo $i | awk -F'/var/tmp/cloud_learn/files/' '{print $2}'`
          echo "    Course $temp_file is broken..."
          echo "$temp_file" >> $BROKEN_FILES
          mv $i $WORK_LOCATION_FILES_BAD/$temp_file
        else
          if [[ "$RENAME_SET" == "no" ]]; then
            if [[ "$i" =~ "ArchiveFile" || "$i" =~ "ExportFile" ]]; then
              echo $i | awk -F'.zip' '{print $1}' | awk -F'File_' -v var=$i '{print $2",", var}'>> $COURSE_IDS
              # if it doesnt come from Bb the course id is just the name of the zip file
            else
              echo $i | awk -F'/var/tmp/cloud_learn/files/' '{print $2}' |awk  -F'.zip' -v var=$i '{print $1",",var}' >> $COURSE_IDS
            fi
          elif [[ "$RENAME_SET" == "yes" ]]; then
            if [[ "$i" =~ "ArchiveFile" || "$i" =~ "ExportFile" ]]; then
              echo $i | awk -F'.zip' '{print $1}' | awk -F'File_' -v var=$i '{print $2"_recover,", var}' >> $COURSE_IDS
              #unzip -c $i .bb-package-info | grep cx.config.course.id | awk -F= -v var="$i" '{print $2"_recover,",var}' >> $COURSE_IDS
              # if it doesnt come from Bb the course id is just the name of the zip file
            else
              echo $i | awk -F'/var/tmp/cloud_learn/files/' '{print $2}'  awk -v var="$i" -F'.zip' '{print $1"_recover,",var}' >> $COURSE_IDS
            fi
          fi
        fi
      done


      ## duplicates
      if [[ ! -f $COURSE_IDS ]]; then
        echo "    Feed file not found. Exiting execution..."
        exit 0
      fi
      echo "  Looking for duplicate files..."
      for i in `cat $COURSE_IDS | awk '{print $2}' | sort | uniq -d`; do
        grep $i $COURSE_IDS
      done > $DUPLICATES

      echo 3 > $IN_PROGRESS_FLAG_FILE
      aws s3 cp $IN_PROGRESS_FLAG_FILE $S3_IN_PROGRESS_FILE --region $region >> $S3_ACTIVITY_LOG

    # user provided feed file
    elif [[ "$FEED_FILE_SET" == "yes" ]]; then
      echo "  Downloading client provided feed file..."
      aws s3 cp $S3_FEED $FEED_FILE --region $region >> ${S3_ACTIVITY_LOG}
      echo "  Client Provided feed file"
      echo "  Looking for broken or corrupted .zip files..."
      columns=`awk -F',' '{print NF}' $FEED_FILE | sort -nu | tail -n 1`



      if [[ "$RENAME_SET" == "yes" ]]; then
        echo "  We don't accept renaming when providing a feed file."
        echo "  Please provide a correct feed file with the names you want."
        echo ""
        exit 1
      fi

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
        if [[ "$local_feed_file" == "yes" ]]; then
          cat $FEED_FILE > $COURSE_IDS
        elif [[ "$local_feed_file" == "no" ]]; then
          for zip_file in `cat $FEED_FILE | awk -F',' '{print $2}'`; do

            if [[ "${zip_file:0:1}" == "/" ]]; then
              # check if its a local path
              if [[ ! "${zip_file:0:26}" == "${WORK_LOCATION_FILES}" ]]; then
                echo "  We don't accept paths in the second column of the feed file. Exiting..."
                echo ""
                exit 1
              fi
            elif [[ ! ${zip_file:0:1} =~ $re && ! "${zip_file:0:1}" == "/"  ]]; then
              file=`ls $WORK_LOCATION_FILES/ | grep $zip_file | head -n1`
              diff_course_id=`grep $zip_file $FEED_FILE | awk -F',' '{print $1}'`
              unzip -t $WORK_LOCATION_FILES/$zip_file &> /dev/null
              if [ $? -ne 0 ] ; then
                echo "    Course $zip_file is broken..."
                echo "$zip_file" >> $BROKEN_FILES
              else
                echo "$diff_course_id, $WORK_LOCATION_FILES/$zip_file" >> $COURSE_IDS
              fi
            fi
          done
        # some other weird format feed file
        else
          echo "    Incorrect feed file type..."
          echo ""
          exit 1
        fi


        if [[ ! -f $COURSE_IDS ]]; then
          echo "    Feed file not found. Exiting execution..."
          exit 1
        fi

        echo "  Looking for duplicate files..."
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
    cp /var/tmp/aire/*monitor*.sh ${WORK_LOCATION}/
    echo "  Giving the right permissions to the monitor..."
    chmod +x ${WORK_LOCATION}/restore-import_monitor_bb_logs.sh

    if [[ $? -ne 0 ]]; then
      echo "There were some errors giving the permissions to the monitors. Exiting.."
    	exit 1
    fi

    echo 4 > $IN_PROGRESS_FLAG_FILE
    aws s3 cp $IN_PROGRESS_FLAG_FILE $S3_IN_PROGRESS_FILE --region $region >> $S3_ACTIVITY_LOG
  fi

  # CREATION OF FEED FILE & AND UPLOAD IT FOR BACKUP
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 4 ]] 2>/dev/null; then
    echo "  Creating Feed file or modifying it based on the duplicate/validity tests..."
    if [[ ! -f $COURSE_IDS ]]; then
      echo "    Feed file not found. Exiting execution..."
      exit 1
    fi
    #feed format - course_id,/path/to/file.zip
    cat $COURSE_IDS > $FEED_FILE


    # upload feed file
    echo "  Backing up the new feed file..."
    aws s3 cp $FEED_FILE $S3_FEED --region $region >> $S3_ACTIVITY_LOG
    echo ${ACTION} > $IN_PROGRESS_FLAG_FILE
    aws s3 cp $IN_PROGRESS_FLAG_FILE $S3_IN_PROGRESS_FILE --region $region >> $S3_ACTIVITY_LOG
  fi

  # EXECUTION
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ ! $in_progress_flag =~ $re || ${#in_progress_flag} -gt 1 ]] 2>/dev/null; then

    columns=`awk -F',' '{print NF}' $FEED_FILE | sort -nu | tail -n 1`
    if [[ $columns -lt 2 ]]; then
      echo "    There was a problem with the feed file. Exiting..."
      exit 1
    fi

    # and we let it run in the background
    echo "  Executing the monitor..."

    ${WORK_LOCATION}/restore-import_monitor_bb_logs.sh ${ACTION} ${CLIENT_ID} ${WORK_LOCATION} ${S3_ROOT_DIR} ${region} ${S3_CURRENT_LOCATION}   &

    if [[ $? -ne 0 ]]; then
      echo "There were some errors executing the monitors. Exiting.."
    	exit 1
    fi

    # clean the logs that will be monitored
    echo "  Deleting any course specific log and moving the content-exchange-log to a date backup ..."
    rm -rf /usr/local/blackboard/logs/content-exchange/BatchCxCmd_*
    if [ -f '/usr/local/blackboard/logs/content-exchange/content-exchange-log.txt' ]; then
      mv /usr/local/blackboard/logs/content-exchange/content-exchange-log.txt /usr/local/blackboard/logs/content-exchange/cloud-content-exchange-log.txt.${DATE}
    fi
    echo "  Executing the Restore/Import..."

    # command to execute
    start_time=`date +%s`
    sudo -u bbuser /usr/local/blackboard/apps/content-exchange/bin/batch_ImportExport.sh -f ${FEED_FILE} -l 1 -t ${ACTION} > ${WORK_LOCATION}/batch_${CLIENT_ID}.log

    sleep 60

    file_to_move=`tail -n1 ${FEED_FILE} | awk -F'/' '{print $6}'`
    if [[ ${S3_CURRENT_LOCATION: -1} == "/" ]]; then
      S3_CURRENT_LOCATION=${S3_CURRENT_LOCATION:0:-1}
    fi

    aws s3 mv $S3_CURRENT_LOCATION/$file_to_move $S3_ROOT_DIR/completed/$file_to_move  --region $region >> $S3_ACTIVITY_LOG

    COMPLETED_COURSE=`ls -t /usr/local/blackboard/logs/content-exchange/BatchCxCmd* | tail -n 2 | grep details.txt | cut -d'_' -f3- | awk -F'_details.txt' '{print $1}'`
    feed_line_count=`wc -l ${FEED_FILE} | awk '{print $1}'`

    echo "    Completed: $feed_line_count of $feed_line_count - $COMPLETED_COURSE"

    echo "  Finish Execution."
    end_time=`date +%s`
    echo "    ${ACTION} took `expr $end_time - $start_time` s."

    # upload the last log file
    for log_file in `ls -t ${BB_LOG_DIR}/BatchCxCmd_*`; do
      aws s3 mv $log_file $S3_INDIVIDUAL_LOGS/ --region $region >> $S3_ACTIVITY_LOG
    done

    # we need to upload the complete log file if this server goes down
    for summary_log in `ls ${BB_LOG_DIR}/content-exchange-log* | awk -F'/' '{print $7}'`; do
      aws s3 mv ${BB_LOG_DIR}/$summary_log $S3_SUMMARY_LOGS/$summary_log-${DATE} --region $region >> $S3_ACTIVITY_LOG
    done

    #aws s3 mv ${WORK_LOCATION}/batch_${CLIENT_ID}.log $S3_LOG_DIR/batch_${CLIENT_ID}.log  >> $S3_ACTIVITY_LOG
    echo 9 > $IN_PROGRESS_FLAG_FILE
    aws s3 cp $IN_PROGRESS_FLAG_FILE $S3_IN_PROGRESS_FILE --region $region >> $S3_ACTIVITY_LOG

  fi

  # summmary
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 9 ]] 2>/dev/null; then
    rm -rf ${FAILED_LOG}
    echo "  Checking for errors and fatals in the failed logs..."

    # if there were files there move them to something else
    feed_line_count=`wc -l ${FEED_FILE} | awk '{print $1}'`
    fatals_count=`grep -c 'Fatal' ${WORK_LOCATION}/batch_${CLIENT_ID}.log*`
    if [[ $fatals_count -gt 0 ]]; then
      echo ""
      #echo "    There were $fatals_count errors out of $feed_line_count"
      for fatal_course in `cat ${WORK_LOCATION}/batch_${CLIENT_ID}.log | grep -B 4 Fatal | grep "Executed" | awk '{print $4}'`; do
        fatal_error=`grep -A4 $fatal_course ${WORK_LOCATION}/batch_${CLIENT_ID}.log | grep -A1 Fatal | grep -vE "Fatal|\--"`
        echo "      $fatal_course - $fatal_error" > $FAILED_LOG
        done
    fi

    if [[ ! -f $FAILED_LOG ]]; then
      echo "    There were no fatals in this execution."
    else
      cat $FAILED_LOG
    fi
  fi


elif [[ "$ACTION" == "archive" || "$ACTION" == "export" ]]; then
  echo ""
  echo "Starting Archive/Export Process"

  # we will skip step 0 = modify volume
  # we sill start in step 1
  # DOWNLOAD of files - in this case the feed file)
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 1 ]] 2>/dev/null; then
    echo "  Downloading feed file from S3..."
    aws s3 cp $S3_FEED $FEED_FILE --region $region >> ${S3_ACTIVITY_LOG}
    if [ $? -eq 0 ]; then
      echo 2 > $IN_PROGRESS_FLAG_FILE
    else
      echo "No feed file exists in S3 and we need a Feed File to proceed. Exiting..."
      echo ""
      exit 1
    fi
    columns=`awk -F',' '{print NF}' $FEED_FILE | sort -nu | tail -n 1`

    if [[ $columns -gt 1 || $columns -eq 0 ]]; then
      echo "Feed file can only contain one column, with the course ids. Exiting..."
      echo ""
      exit 1
    else
      sed  -i 's/$/,\/var\/tmp\/cloud_learn\/files\/,true,true,true/' $FEED_FILE
    fi
  fi

  # TEST FEED FILE
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 2 ]] 2>/dev/null; then
    echo "  Testing feed file..."
      dos2unix $FEED_FILE 2>/dev/null
      echo 3 > $IN_PROGRESS_FLAG_FILE
  fi

  # CREATION OF MONITOR FILE
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 3 ]] 2>/dev/null; then
    echo "  Giving the right permissions to the monitors..."
    cp /var/tmp/aire/*monitor*.sh ${WORK_LOCATION}/

    chmod +x ${WORK_LOCATION}/archive-export_monitor_bb_logs.sh
    chmod +x ${WORK_LOCATION}/archive-export_monitor_zip_files.sh

    if [[ $? -ne 0 ]]; then
      echo "There were some errors giving the right permissions to the monitors. Exiting.."
    	exit 1
    fi

    echo 4 > $IN_PROGRESS_FLAG_FILE
    aws s3 cp $IN_PROGRESS_FLAG_FILE $S3_IN_PROGRESS_FILE --region $region >> $S3_ACTIVITY_LOG
  fi

  # CREATION OF FEED FILE & AND UPLOAD IT FOR BACKUP
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 4 ]] 2>/dev/null; then
    echo "  Uploading modified feed file..."
    aws s3 cp $FEED_FILE $S3_FEED --region $region >> ${S3_ACTIVITY_LOG}
    echo $ACTION > $IN_PROGRESS_FLAG_FILE
  fi

  # execution
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ ! $in_progress_flag =~ $re  || ${#in_progress_flag} -gt 1 ]] 2>/dev/null; then

    echo "  Executing the monitors..."
    ${WORK_LOCATION}/archive-export_monitor_bb_logs.sh ${ACTION} ${CLIENT_ID} ${WORK_LOCATION} ${S3_ROOT_DIR} ${region}   & 2>/dev/null
    ${WORK_LOCATION}/archive-export_monitor_zip_files.sh ${ACTION} ${CLIENT_ID} ${WORK_LOCATION} ${S3_ROOT_DIR} ${region}   & 2>/dev/null

    if [[ $? -ne 0 ]]; then
      echo "There were some errors executing the monitors. Exiting.."
    	exit 1
    fi


    # clean the logs that will be monitored
    echo "  Deleting any course specific log and moving the content-exchange-log to a date backup ..."
    rm -rf /usr/local/blackboard/logs/content-exchange/BatchCxCmd_*
    if [ -f '/usr/local/blackboard/logs/content-exchange/content-exchange-log.txt' ]; then
      mv /usr/local/blackboard/logs/content-exchange/content-exchange-log.txt /usr/local/blackboard/logs/content-exchange/cloud-content-exchange-log-old.txt.${DATE}
    fi
    echo "  Executing the Archive/Export..."

    # command to execute
    start_time=`date +%s`
    sudo -u bbuser /usr/local/blackboard/apps/content-exchange/bin/batch_ImportExport.sh -f ${FEED_FILE} -l 1 -t ${ACTION} > ${WORK_LOCATION}/batch_${CLIENT_ID}.log
    sleep 60

    COMPLETED_COURSE=`ls -t /usr/local/blackboard/logs/content-exchange/BatchCxCmd* | tail -n 2| grep details.txt | cut -d'_' -f3- | awk -F'_details.txt' '{print $1}'`

    feed_line_count=`wc -l ${FEED_FILE} | awk '{print $1}'`
    echo "    Completed: $feed_line_count of $feed_line_count - $COMPLETED_COURSE "
    echo ""
    echo "    Completed files will be moved to: ${S3_ROOT_DIR}/completed/"
    echo ""
    echo "  Finish Execution."
    end_time=`date +%s`
    echo "    ${ACTION} took `expr $end_time - $start_time` s."

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
      aws s3 mv ${BB_LOG_DIR}/$summary_log $S3_SUMMARY_LOGS/ --region $region >> $S3_ACTIVITY_LOG
    done
    #aws s3 mv ${WORK_LOCATION}/batch_${CLIENT_ID}.log $S3_LOG_DIR/batch_${CLIENT_ID}.log >> $S3_ACTIVITY_LOG

    echo 9 > $IN_PROGRESS_FLAG_FILE
    aws s3 cp $IN_PROGRESS_FLAG_FILE $S3_IN_PROGRESS_FILE --region $region >> $S3_ACTIVITY_LOG

  fi

  # summmary
  in_progress_flag=`cat $IN_PROGRESS_FLAG_FILE`
  if [[ $in_progress_flag -eq 9 ]] 2>/dev/null; then
    rm -rf ${FAILED_LOG}
    echo "  Checking for errors and fatals in the failed logs..."
    #for file in `aws s3 ls ${$S3_LOG_DIR}/ --region ${region} | grep batch | awk '{print $4}'`; do
    #  aws s3 cp ${$S3_LOG_DIR}/$file ${WORK_LOCATION}/$file >> $S3_ACTIVITY_LOG
    #done

    fatals_count=`grep -c 'Fatal' ${WORK_LOCATION}/batch_${CLIENT_ID}.log*`
    feed_line_count=`wc -l ${FEED_FILE} | awk '{print $1}'`
    if [[ $fatals_count -gt 0 ]]; then
      echo ""
      #echo "    There were $fatals_count errors out of $feed_line_count"
      for fatal_course in `cat ${WORK_LOCATION}/batch_${CLIENT_ID}.log | grep -B 4 Fatal | grep "Executed" | awk '{print $4}'`; do
        fatal_error=`grep -A4 $fatal_course ${WORK_LOCATION}/batch_${CLIENT_ID}.log | grep -A1 Fatal | grep -vE "Fatal|\--"`
        echo "      $fatal_course - $fatal_error" > $FAILED_LOG
        done
    fi

    if [[ ! -f $FAILED_LOG ]]; then
      echo "    There were no fatals in this execution."
    else
      cat $FAILED_LOG
    fi

  fi

fi


script_end_time=`date +%s`
echo ""
echo "TOTAL EXECUTION TIME: `expr $script_end_time - $script_start_time` s."
echo ""

echo "debugging...."
echo ""
ps -ef | grep inotifywait
echo ""
ps -ef | grep /bin/bash
echo "end debugging...."
echo ""
echo "Script completed."
echo ""
sudo killall /bin/bash
sudo killall inotifywait
exit 0
