#!/bin/bash

ACTION=$1
S3_CURRENT_LOCATION=$2

CONTENT_LOGS="/usr/local/blackboard/logs/content-exchange"
DATE=`date +%Y-%m-%d_%H-%M-%S`

if [[ ! -d ${CONTENT_LOGS} ]]; then
  sudo mkdir -p /usr/local/blackboard/logs/content-exchange/
  sudo chown bbuser: /usr/local/blackboard/logs/content-exchange/
  sudo chmod 755 /usr/local/blackboard/logs/content-exchange/
else
  sudo cp -rp ${CONTENT_LOGS} ${CONTENT_LOGS}-${DATE} && sudo rm -rf ${CONTENT_LOGS}/*
fi

# add jq to the ubuntu repo 16.04
if [ "$(grep -c 'deb http://us.archive.ubuntu.com/ubuntu xenial main universe'   /etc/apt/sources.list)" -eq 0 ]; then
  echo "deb http://us.archive.ubuntu.com/ubuntu xenial main universe" >> /etc/apt/sources.list
fi

# update the repos and install dependencies
echo "Installing dependencies..."
echo "  Updating the sources..."
sudo apt-get update > /dev/null 2>&1
echo "  Installing tools..."
sudo apt-get install -y inotify-tools dos2unix jq  bc > /dev/null 2>&1
echo "  Updating awscli..."
sudo pip install --upgrade awscli > /dev/null 2>&1


region=`curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | awk -F'"' '/\"region\"/ { print $4 }'`
instance_id=`curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | awk -F'"' '/\"instanceId\"/ { print $4 }'`
volume_id=`aws ec2 describe-instances --instance-id $instance_id --region $region | jq '.Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId' | tr -d '"'`
volume_size=`aws ec2 describe-volumes --volume-ids $volume_id --region $region | jq '.Volumes[].Size'`

# get directory size in s3
# Bytes/MiB/KiB/GiB/TiB/PiB/EiB types
echo "Reading the required volume size..."
if [[ "$ACTION" == "restore" || "$ACTION" == "import" ]]; then

  if [[ ${S3_CURRENT_LOCATION: -1} == "/" ]]; then
  	S3_CURRENT_LOCATION=${S3_CURRENT_LOCATION:0:-1}
  fi

  files_size=`aws s3 ls "${S3_CURRENT_LOCATION}/" --summarize --human-readable --region $region | tail -n1 | awk '{print $3,$4}'`

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
    echo "  Not accepting Tera / Penta / Exbi - Bytes at this time.. exiting"
    echo ""
    exit 1
  fi
else
  required_size=100
fi

echo "  Required volume size: $required_size"
echo "  Modifying volume size..."

if [[ "$required_size" == "$volume_size" ]]; then
  echo "    No need to modify the volume is already the correct size"
else
  aws ec2 modify-volume --volume-id $volume_id --size $required_size --region $region
  if [ $? -ne 0 ] ; then
    echo ""
    echo "    There was a problem modifying the volume. Exiting..."
    echo ""
    exit 1
  fi

fi


echo "    Modification Complete"
