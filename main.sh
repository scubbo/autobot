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

ACCOUNT_ID=$(aws iam get-user | jq -r '.User .UserId');

# Create Lambda Role
LAMBDA_ROLE_NAME=$PROJECT_NAME"_lambda-role";
LAMBDA_ROLE_ARN=$(aws iam list-roles | jq -r --arg ROLE_NAME $LAMBDA_ROLE_NAME '.Roles[] | select(.RoleName==$ROLE_NAME) | .Arn');
if [[ -z $LAMBDA_ROLE_ARN ]]; then
  LAMBDA_ROLE_ARN=$(aws iam create-role --role-name $LAMBDA_ROLE_NAME --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Action":"sts:AssumeRole","Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"}}]}' --description "Created by $SCRIPT_NAME" | jq -r '.Role .Arn');
  sleep 5; # https://stackoverflow.com/a/37438525/1040915 :(
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
API_NAME=$PROJECT_NAME"_api";
API_ID=$(aws apigateway get-rest-apis | jq -r --arg API_NAME $API_NAME '.items[] | select(.name==$API_NAME) | .id');
if [[ -z $API_ID ]]; then
  API_ID=$(aws apigateway create-rest-api --name $API_NAME | jq -r '.id');
fi

ROOT_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id $API_ID | jq -r '.items[] | select(.path=="/") | .id')
RESOURCE_ID=$(aws apigateway get-resources --rest-api-id $API_ID | jq -r '.items[] | select(.path=="/slack") | .id')
if [[ -z $RESOURCE_ID ]]; then
  RESOURCE_ID=$(aws apigateway create-resource --rest-api-id $API_ID --parent-id $ROOT_RESOURCE_ID --path-part slack | jq -r '.id');
fi

# Need to temporarily disable the "if non-zero, then exit" behaviour (look for a "set -e", below)
set +e
aws apigateway get-method --rest-api-id $API_ID --resource-id $RESOURCE_ID --http-method POST >/dev/null 2>&1;
# We don't get a "return" value, per se, but just check for succesful completion or not...
if [[ $? -ne 0 ]]; then
  aws apigateway put-method --rest-api-id $API_ID --resource-id $RESOURCE_ID --http-method POST --authorization-type NONE --no-api-key-required >/dev/null 2>&1;
fi

aws apigateway get-integration --rest-api-id $API_ID --resource-id $RESOURCE_ID --http-method POST >/dev/null 2>&1;
# Ditto above re: return values
if [[ $? -ne 0 ]]; then
  # Yes, this assumes that we're in us-east-1, because 'MURICA
  URI="arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:"$ACCOUNT_ID":function:"$LAMBDA_FUNCTION_NAME"/invocations";
  aws apigateway put-integration --rest-api-id $API_ID --resource-id $RESOURCE_ID --http-method POST --integration-http-method POST --type AWS_PROXY --uri $URI >/dev/null 2>&1;
fi

aws apigateway get-method-response --rest-api-id $API_ID --resource-id $RESOURCE_ID --http-method POST --status-code 200 >/dev/null 2>&1;
# And again
if [[ $? -ne 0 ]]; then
  aws apigateway put-method-response --rest-api-id $API_ID --resource-id $RESOURCE_ID --http-method POST --status-code 200 --response-models "{}" >/dev/null 2>&1;
fi

# Grant permission for the APIGateway to call the Lambda function
# With thanks to billjf of https://forums.aws.amazon.com/thread.jspa?threadID=217254&tstart=0
STATEMENT_ID=$(cat /dev/urandom | od -vAn -N4 -tu4 | perl -pe 's/\s//g') # https://www.cyberciti.biz/faq/bash-shell-script-generating-random-numbers/
aws add-permission --function-name $LAMBDA_FUNCTION_ARN --source-arn "arn:aws:execute-api:us-east-1:""$ACCOUNT_ID""$API_ID""/*/POST/slack" --principal apigateway.amazonaws.com --statement-id $STATEMENT_ID --action lambda:InvokeFunction

# Make a test request against this endpoint
curl "https://"$API_ID".execute-api.us-east-1.amazonaws.com/prod/slack"

set -e
