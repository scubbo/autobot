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
EXISTING_LAMBDA_ROLE_ARN=$(aws iam list-roles | jq -r --arg ROLE_NAME $PROJECT_NAME"-lambda_role" '.Roles[] | select(.RoleName==$ROLE_NAME) | .Arn')
if [[ -z $EXISTING_LAMBDA_ROLE_ARN ]]; then
  EXISTING_LAMBDA_ROLE_ARN=$(aws iam create-role --role-name $PROJECT_NAME"-lambda_role" --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Action":"sts:AssumeRole","Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"}}]}' | jq -r '.Role .Arn');
  sleep 2; # https://stackoverflow.com/a/37438525/1040915 :(
fi

# Create function

# Create API
