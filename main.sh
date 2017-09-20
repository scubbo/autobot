#!/bin/bash

SCRIPT_NAME="AutoBot"

# https://stackoverflow.com/a/14203146/1040915
while [[ $# -gt 1 ]]
do
key="$1"
case $key in
    -n|--name)
    PROJECT_NAME="$2"
    shift # past argument
    ;;
    *)
            # unknown option
    ;;
esac
shift # past argument or value
done

# https://stackoverflow.com/a/677212/1040915
hash jq 2>/dev/null || { echo >&2 "This script requires jq, but it's not installed.  Try getting it from https://github.com/stedolan/jq/wiki/Installation. Aborting."; exit 1; }
hash aws 2>/dev/null || { echo >&2 "This script requires aws, but it's not installed.  Aborting."; exit 1; }

set -e

if [[ -z $PROJECT_NAME ]]; then
  echo "Expected to receive a value for -n/--name. Aborting";
  exit 1;
fi

# Create Lambda Role
LAMBDA_ROLE_NAME=$PROJECT_NAME"_lambda-role";
LAMBDA_ROLE_ARN=$(aws iam list-roles | jq -r --arg ROLE_NAME $LAMBDA_ROLE_NAME '.Roles[] | select(.RoleName==$ROLE_NAME) | .Arn');
if [[ -z $LAMBDA_ROLE_ARN ]]; then
  LAMBDA_ROLE_ARN=$(aws iam create-role --role-name $LAMBDA_ROLE_NAME --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Action":"sts:AssumeRole","Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"}}]}' --description "Created by $SCRIPT_NAME" | jq -r '.Role .Arn');
  sleep 2; # https://stackoverflow.com/a/37438525/1040915 :(
fi

# Create function
LAMBDA_FUNCTION_NAME=$PROJECT_NAME"_lambda-function";
LAMBDA_FUNCTION_ARN=$(aws lambda list-functions | jq -r --arg FUNCTION_NAME $LAMBDA_FUNCTION_NAME '.Functions[] | select(.FunctionName==$FUNCTION_NAME) | .FunctionArn');
if [[ -z $LAMBDA_FUNCTION_ARN ]]; then
  # Lambda creation requires a non-empty zip file
  # TODO we can probably get rid of this altogether if we've already created a repo by this point
  mkdir /tmp/"$PROJECT_NAME""_temp";
  cd /tmp/"$PROJECT_NAME""_temp";
  echo 'hello' >> foo
  zip lambda.zip foo
  LAMBDA_FUNCTION_ARN=$(aws lambda create-function --function-name $LAMBDA_FUNCTION_NAME --runtime python2.7 --role $LAMBDA_ROLE_ARN --zip-file fileb://lambda.zip --handler main.lambda_handler --description "Created by $SCRIPT_NAME" | jq -r '.FunctionArn');
  cd -
  rm -rf /tmp/"$PROJECT_NAME""_temp";
fi

# Create API
