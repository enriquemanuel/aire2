#!/bin/bash
ACTION=$1
CLIENT_ID=$2
WORK_LOCATION=$3
S3_ROOT_DIR=$4
REGION=$5
S3_CURRENT_LOCATION=$6
COUNTER=0
WORK_COUNTER_INT=0
WORK_COUNTER_TOTAL=`wc -l $WORK_LOCATION/feed.txt | awk '{print $1}'`
IN_PROGRESS_FLAG_FILE="${WORK_LOCATION}/in_progress.txt"
S3_IN_PROGRESS_FILE="${S3_ROOT_DIR}/in_progress.txt"
S3_ACTIVITY_LOG="${WORK_LOCATION}/S3_${CLIENT_ID}_${ACTION}.log"
S3_LOG_DIR="${S3_ROOT_DIR}/logs"
S3_INDIVIDUAL_LOGS="${S3_LOG_DIR}/individual/"
ACTIVITY_LOG="${WORK_LOCATION}/${CLIENT_ID}_${ACTION}.log"

inotifywait -m /usr/local/blackboard/logs/content-exchange/ -e create | while read path action file; do

  if [[ "$file" =~ "BatchCxCmd" && "$file" =~ "details.txt" ]]; then
    COUNTER=$((COUNTER+1))

    if [[ $COUNTER -eq 2 ]]; then
      COMPLETED_COURSE=`ls -t /usr/local/blackboard/logs/content-exchange/BatchCxCmd* | tail -n 2 | grep details.txt | cut -d'_' -f3- | awk -F'_details.txt' '{print $1}'`
      WORK_COUNTER_INT=$((WORK_COUNTER_INT+1))
      COUNTER=1
      echo $COMPLETED_COURSE > $IN_PROGRESS_FLAG_FILE

      # upload the flag file
      aws s3 cp $IN_PROGRESS_FLAG_FILE $S3_IN_PROGRESS_FILE --region $REGION  >> $S3_ACTIVITY_LOG

      # upload logs cause they can be deleted
      for log_file in `ls -t /usr/local/blackboard/logs/content-exchange/*${COMPLETED_COURSE}*`; do
        aws s3 mv $log_file $S3_INDIVIDUAL_LOGS >> $S3_ACTIVITY_LOG
      done

      # move the source zip file
      file_to_move=`grep $COMPLETED_COURSE $WORK_LOCATION/feed.txt | awk '{print $2}' | awk -F'/' '{print $6}'`
      if [[ ${S3_CURRENT_LOCATION: -1} == "/" ]]; then
        S3_CURRENT_LOCATION=${S3_CURRENT_LOCATION:0:-1}
      fi
      aws s3 mv $S3_CURRENT_LOCATION/$file_to_move $S3_ROOT_DIR/completed/$file_to_move  --region $REGION --dryrun

      # display counter
      echo "    Completed: $WORK_COUNTER_INT of $WORK_COUNTER_TOTAL"

    fi
  fi
done
