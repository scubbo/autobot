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

CF_ROLE_NAME=$PROJECT_NAME"_cloudformation-role";
CF_ROLE_ARN=$(aws iam list-roles | jq -r --arg ROLE_NAME $CF_ROLE_NAME '.Roles[] | select (.RoleName==$ROLE_NAME) | .Arn');
CF_POLICY_ARN="arn:aws:iam::aws:policy/AWSLambdaExecute";
CF_POLICY_2_NAME=$PROJECT_NAME"_cloudformation-policy";
if [[ -z $CF_ROLE_ARN ]]; then
  CF_ROLE_ARN=$(aws iam create-role --role-name $CF_ROLE_NAME --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Action":"sts:AssumeRole","Effect":"Allow","Principal":{"Service":"cloudformation.amazonaws.com"}}]}' --description "Created by $SCRIPT_NAME" | jq -r '.Role .Arn');
  aws iam attach-role-policy --role-name $CF_ROLE_NAME --policy-arn $CF_POLICY_ARN;
  # http://docs.aws.amazon.com/lambda/latest/dg/automating-deployment.html
  CF_POLICY_2_ARN=$(aws iam create-policy --policy-name $CF_POLICY_2_NAME --policy-document '{"Statement":[{"Action":["s3:GetObject","s3:GetObjectVersion","s3:GetBucketVersioning"],"Resource":"*","Effect":"Allow"},{"Action":["s3:PutObject"],"Resource":["arn:aws:s3:::codepipeline*"],"Effect":"Allow"},{"Action":["lambda:*"],"Resource":["arn:aws:lambda:us-east-1:'$ACCOUNT_ID':function:*"],"Effect":"Allow"},{"Action":["apigateway:*"],"Resource":["arn:aws:apigateway:us-east-1::*"],"Effect":"Allow"},{"Action":["iam:GetRole","iam:CreateRole","iam:DeleteRole"],"Resource":["arn:aws:iam::'$ACCOUNT_ID':role/*"],"Effect":"Allow"},{"Action":["iam:AttachRolePolicy","iam:DetachRolePolicy"],"Resource":["arn:aws:iam::'$ACCOUNT_ID':role/*"],"Effect":"Allow"},{"Action":["iam:PassRole"],"Resource":["*"],"Effect":"Allow"},{"Action":["cloudformation:CreateChangeSet"],"Resource":["arn:aws:cloudformation:us-east-1:aws:transform/Serverless-2016-10-31"],"Effect":"Allow"}],"Version":"2012-10-17"}' --description "Created with $SCRIPT_NAME" | jq -r '.Policy .Arn');
  sleep 10; # https://stackoverflow.com/a/37438525/1040915 :(
  aws iam attach-role-policy --role-name $CF_ROLE_NAME --policy-arn $CF_POLICY_2_ARN;
  echo "Role $CF_ROLE_NAME created.";
fi

# Create quasi-managed CodePipeline role if not created already
# http://docs.aws.amazon.com/codepipeline/latest/userguide/iam-identity-based-access-control.html
CODE_PIPELINE_ROLE_ARN=$(aws iam list-roles | jq -r '.Roles[] | select(.RoleName=="AWS-CodePipeline-Service") | .Arn');
if [[ -z $CODE_PIPELINE_ROLE_ARN ]]; then
  CODE_PIPELINE_ROLE_ARN=$(aws iam create-role --role-name "AWS-CodePipeline-Service" --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Action":"sts:AssumeRole","Principal":{"Service":"codepipeline.amazonaws.com"},"Effect":"Allow","Sid":""}]}' | jq -r '.Role .Arn');
  CODE_PIPELINE_POLICY_ARN=$(aws iam create-policy --policy-name "CodePipelineRole" --policy-document file://codePipelinePolicyStatement.json --description "Copied from http://docs.aws.amazon.com/codepipeline/latest/userguide/iam-identity-based-access-control.html by $SCRIPT_NAME" | jq -r '.Policy .Arn');
  sleep 10; # https://stackoverflow.com/a/37438525/1040915 :(
  aws iam attach-role-policy --role-name $CODE_PIPELINE_ROLE_ARN --policy-arn $CODE_PIPELINE_POLICY_ARN;
  echo "Created CodePipeline role with name $CF_ROLE_NAME";
fi

# Note that this breaches the usual pattern of following PROJECT_NAME with an underscore, because of limitations on S3 bucket names when creating pipelines
BUCKET_NAME=$PROJECT_NAME"-s3-bucket";
S3_BUCKET_EXISTS=$(aws s3api list-buckets | jq -r --arg BUCKET_NAME $BUCKET_NAME '.Buckets[] | select(.Name==$BUCKET_NAME)' | wc -l | perl -pe 's/\s//g');
if [[ "$S3_BUCKET_EXISTS" -eq 0 ]]; then
  aws s3api create-bucket --bucket $BUCKET_NAME 2>&1 >/dev/null;
  echo "Created S3 bucket $BUCKET_NAME";
fi

# https://github.com/stelligent/dromedary
echo "We need an OAuth token from GitHub to continue. Go to \"https://github.com/settings/tokens\", click \"Generate New Token\", enter a description, and select the scopes \"admin:repo_hook\" and \"repo\". Copy it below.";
read -p ">>> " GITHUB_OAUTH_TOKEN;
# TODO: later, should provide ability to create this afresh
echo "And what repo should we be looking at?";
read -p ">>> " GITHUB_REPO;

PIPELINE_NAME=$PROJECT_NAME"_pipeline";
GITHUB_USER=$(ssh -T git@github.com 2>&1 | perl -pe 's/Hi (.*?)!.*/$1/');
BUILT_PROJECT_NAME=$PROJECT_NAME"_built";
cat template-pipeline-definition.json | perl -pe "s/__ROLE_ARN__/$(echo $CODE_PIPELINE_ROLE_ARN | perl -pe 's/\//\\\//')/" | perl -pe "s/__APP_NAME__/$PROJECT_NAME/" | perl -pe "s/__GITHUB_USER__/$GITHUB_USER/" | perl -pe "s/__GITHUB_REPO__/$GITHUB_REPO/" | perl -pe "s/__GITHUB_OAUTH_TOKEN__/$GITHUB_OAUTH_TOKEN/" | perl -pe "s/__BUILT_APP_NAME__/$BUILT_PROJECT_NAME/" | perl -pe "s/__PROJECT_NAME__/$PROJECT_NAME/" | perl -pe "s/__ROLE_ARN_2__/$(echo $CF_ROLE_ARN | perl -pe 's/\//\\\//')/" | perl -pe "s/__BUCKET_NAME__/$BUCKET_NAME/" | perl -pe "s/__PIPELINE_NAME__/$PIPELINE_NAME/" >> pipeline-definition.json;
aws codepipeline create-pipeline --pipeline file://pipeline-definition.json 2>&1 >/dev/null
echo "Created pipeline with name $PIPELINE_NAME";
# rm pipeline-definition.json - not til I've guaranteed working right.
