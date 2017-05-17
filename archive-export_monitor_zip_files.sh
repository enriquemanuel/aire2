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
S3_ACTIVITY_LOG="${WORK_LOCATION}/S3_${CLIENT_ID}_${ACTION}.log"
ACTIVITY_LOG="${WORK_LOCATION}/${CLIENT_ID}_${ACTION}.log"

inotifywait -m /var/tmp/cloud_learn/files/ -e create | while read path action file; do

  COUNTER=$((COUNTER+1))
  if [[ $COUNTER -eq 2 ]]; then
    COMPLETED_FILE=`ls -t /var/tmp/cloud_learn/files/ |  tail -n 1`
    aws s3 mv /var/tmp/cloud_learn/files/${COMPLETED_FILE} ${S3_FILES} --region $REGION >> $S3_ACTIVITY_LOG
    COUNTER=1
    WORK_COUNTER_INT=$((WORK_COUNTER_INT+1))
    echo "    Completed: $WORK_COUNTER_INT of $WORK_COUNTER_TOTAL"
  fi
done
