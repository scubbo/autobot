#!/bin/bash

# https://stackoverflow.com/a/677212/1040915
hash jq 2>/dev/null || { echo >&2 "This script requires jq, but it's not installed.  Try getting it from https://github.com/stedolan/jq/wiki/Installation. Aborting."; exit 1; }
hash aws 2>/dev/null || { echo >&2 "This script requires aws, but it's not installed.  Aborting."; exit 1; }

set -e

echo "Hi there! This script will walk you through the process of creating a Slackbot hosted on AWS";
echo "First off, what's your project name? (We'll use this in naming of various resources). No whitespace or dodgy characters, please - alphanumeric only.";
read -p ">>> " PROJECT_NAME;
echo "OK! Working...";

STACK_NAME=$PROJECT_NAME"-stack";

aws cloudformation create-stack --stack-name $STACK_NAME --template-body file://fullTemplate.json --parameters ParameterKey=paramProjectName,ParameterValue=mytestproject --capabilities CAPABILITY_IAM 2>&1 >/dev/null;

STACK_STATUS="Wanna Thank Your Mother For A Butt Like That";
printf "Building your stack..";
BUILDING_WAITS=0
while [ "$STACK_STATUS" != "CREATE_COMPLETE" ]; do
  printf ".";
  sleep 2;
  STACK_STATUS=$(aws cloudformation describe-stacks | jq --arg STACK_NAME $STACK_NAME -r '.Stacks[] | select(.StackName==$STACK_NAME) | .StackStatus');
  let BUILDING_WAITS+=1;
  if [ $BUILDING_WAITS -gt 30 ]; then
    echo "Looks like something went wrong while building your stack. Check the AWS Console to find out what.";
    exit 1;
  fi
done

CALL_URL=$(aws cloudformation describe-stacks | jq --arg STACK_NAME $STACK_NAME -r '.Stacks[] | select(.StackName==$STACK_NAME) | .Outputs[0] .OutputValue')
echo
echo $CALL_URL
if [ $(curl -s -d '{"val":3}' $CALL_URL) != "15" ]; then
  echo "Whoops! Sorry. Something went wrong. To be quite honest, I'm not sure what - you should check your created resources and find out."
  echo "(For your reference, I ran \`curl -s -d '{"val":3}' "$CALL_URL"\` and expected the response \`15\`)";
  exit 1;
fi

echo "OK, sweet! Your stack is all set up and appears to be responding correctly. Now to set it up to handle Slack traffic";
# TODO: that.
