#!/bin/bash

SCRIPT_NAME="AutoBot";

set -e

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

hash aws 2>/dev/null || { echo >&2 "This script requires aws, but it's not installed.  Aborting."; exit 1; }
ACCOUNT_ID=$(aws iam get-user | jq -r '.User .UserId');

if [[ -z $PROJECT_NAME ]]; then
  echo "What is the project name?";
  read -p ">>> " PROJECT_NAME;
fi

echo "Do you have an existing GitHub repo we should link to? [y/n]";
read -p ">>> " REPO_ALREADY_EXISTS;
if [[ "y" -eq "$REPO_ALREADY_EXISTS" ]]; then
  echo "OK! We're not doing anything with this right now, but in later commits I'll need the address here";
  #TODO: do this
else
  echo "OK! We're not doing anything with this right now, but in later commits I'll introduce code to create a repo";
  #TODO: do this
fi

CF_ROLE_NAME=$PROJECT_NAME"_cloudformation-role";
CF_ROLE_ARN=$(aws iam list-roles | jq -r --arg ROLE_NAME $CF_ROLE_NAME '.Roles[] | select (.RoleName==$ROLE_NAME) | .Arn');
CF_POLICY_ARN="arn:aws:iam::aws:policy/AWSLambdaExecute";
CF_POLICY_2_NAME=$PROJECT_NAME"_cloudformation-policy";
if [[ -z $CF_ROLE_ARN ]]; then
  CF_ROLE_ARN=$(aws iam create-role --role-name $CF_ROLE_NAME --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Action":"sts:AssumeRole","Effect":"Allow","Principal":{"Service":"cloudformation.amazonaws.com"}}]}' --description "Created by $SCRIPT_NAME" | jq -r '.Role .Arn');
  aws iam attach-role-policy --role-name $CF_ROLE_NAME --policy-arn $CF_POLICY_ARN;
  # http://docs.aws.amazon.com/lambda/latest/dg/automating-deployment.html
  CF_POLICY_2_ARN=$(aws iam create-policy --policy-name $CF_POLICY_2_NAME --policy-document '{"Statement":[{"Action":["s3:GetObject","s3:GetObjectVersion","s3:GetBucketVersioning"],"Resource":"*","Effect":"Allow"},{"Action":["s3:PutObject"],"Resource":["arn:aws:s3:::codepipeline*"],"Effect":"Allow"},{"Action":["lambda:*"],"Resource":["arn:aws:lambda:us-east-1:'$ACCOUNT_ID':function:*"],"Effect":"Allow"},{"Action":["apigateway:*"],"Resource":["arn:aws:apigateway:us-east-1::*"],"Effect":"Allow"},{"Action":["iam:GetRole","iam:CreateRole","iam:DeleteRole"],"Resource":["arn:aws:iam::'$ACCOUNT_ID':role/*"],"Effect":"Allow"},{"Action":["iam:AttachRolePolicy","iam:DetachRolePolicy"],"Resource":["arn:aws:iam::'$ACCOUNT_ID':role/*"],"Effect":"Allow"},{"Action":["iam:PassRole"],"Resource":["*"],"Effect":"Allow"},{"Action":["cloudformation:CreateChangeSet"],"Resource":["arn:aws:cloudformation:us-east-1:aws:transform/Serverless-2016-10-31"],"Effect":"Allow"}],"Version":"2012-10-17"}' --description "Created with $SCRIPT_NAME" | jq -r '.Policy .Arn');
  aws iam attach-role-policy --role-name $CF_ROLE_NAME --policy-arn $CF_POLICY_2_ARN;
  sleep 10; # https://stackoverflow.com/a/37438525/1040915 :(
  echo "Role $CF_ROLE_NAME created.";
fi
