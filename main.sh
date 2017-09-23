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
  # https://forums.aws.amazon.com/thread.jspa?threadID=179191
  aws iam attach-role-policy --role-name $LAMBDA_ROLE_NAME --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole";
  sleep 5; # https://stackoverflow.com/a/37438525/1040915 :(
fi

# Create function
LAMBDA_FUNCTION_NAME=$PROJECT_NAME"_lambda-function";
LAMBDA_FUNCTION_ARN=$(aws lambda list-functions | jq -r --arg FUNCTION_NAME $LAMBDA_FUNCTION_NAME '.Functions[] | select(.FunctionName==$FUNCTION_NAME) | .FunctionArn');
if [[ -z $LAMBDA_FUNCTION_ARN ]]; then
  mv initialHandler.py main.py
  zip lambda.zip main.py
  LAMBDA_FUNCTION_ARN=$(aws lambda create-function --function-name $LAMBDA_FUNCTION_NAME --runtime python2.7 --role $LAMBDA_ROLE_ARN --zip-file fileb://lambda.zip --handler main.lambda_handler --description "Created by $SCRIPT_NAME" | jq -r '.FunctionArn');
  rm lambda.zip
  mv main.py initialHandler.py
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
# Back to die-on-error behaviour
set -e

# Deploy the API
DEPLOYMENT_ID=$(aws apigateway create-deployment --rest-api-id $API_ID --stage-name prod | jq -r '.id');

# Grant permission for the APIGateway to call the Lambda function
# With thanks to billjf of https://forums.aws.amazon.com/thread.jspa?threadID=217254&tstart=0
STATEMENT_ID=$(cat /dev/urandom | od -vAn -N4 -tu4 | perl -pe 's/\s//g') # https://www.cyberciti.biz/faq/bash-shell-script-generating-random-numbers/
aws add-permission --function-name $LAMBDA_FUNCTION_ARN --source-arn "arn:aws:execute-api:us-east-1:""$ACCOUNT_ID""$API_ID""/*/POST/slack" --principal apigateway.amazonaws.com --statement-id $STATEMENT_ID --action lambda:InvokeFunction;

# Make a test request against this endpoint
RESPONSE_FROM_API=$(curl --silent -d '{"challenge":"abc123"}' "https://"$API_ID".execute-api.us-east-1.amazonaws.com/prod/slack");
if [[ $RESPONSE_FROM_API -ne "abc123" ]]; then
  echo "Sorry, something went wrong. The deployed API didn't respond correctly to the issued challenge.";
  exit 1;
fi

echo "Now comes the manual bit (sorry!)";
echo "Go to https://api.slack.com";
echo "Click \"Your Apps\" in the top-right";
echo "Click \"Create New App\"";
echo "Fill in whatever App Name you like, and pick your Workspace";
echo "Go to \"OAuth & Permissions\", and, under Scopes, enter \"channels:history\" and \"groups:history\". Save Changes.";
echo "Under \"Event Subscriptions\", turn the slider to \"On\", then paste this into the Request Url: \"https://"$API_ID".execute-api.us-east-1.amazonaws.com/prod/slack\". After a second or two, you should see a green \"Verified\".";
echo "On the same page, under \"Subscribe to Workspace Events\", click \"Add Workspace Event\" and add \"message.channels\" and \"message.groups\"";
echo "Save changes (in the bottom-right)";
echo "Under \"Bot Users\", click \"Add a Bot User\", and fill in the values however you wish. Make sure to Save Changes when you're done.";
echo "Go back to \"OAuth & Permissions\", click \"Install App to Workspace\", and click \"Authorize\"";
echo "Copy the \"Bot User OAuth Access Token\", and enter it below (I encourage you to read the source of this script to ensure no shenanigans are going on!)"
read BOT_ACCESS_TOKEN
aws lambda update-function-configuration --function-name $LAMBDA_FUNCTION_ARN --environment "Variables={responseToken=$BOT_ACCESS_TOKEN}" >/dev/null;
echo "One moment...making the bot's response a little more exciting..."

mv sampleHandler.py main.py
zip --quiet lambda.zip main.py
aws lambda update-function-code --function-name $LAMBDA_FUNCTION_NAME --zip-file fileb://lambda.zip >/dev/null
rm lambda.zip
mv main.py sampleHandler.py

echo "OK, go to your Slack workspace, and post a message beginning with \"Hey Bot!\" in any public channel. You should get a response!";
echo "OK, you're done! I hope this was fun and helpful! Check out the repo at https://github.com/scubbo/autobot, and please feel free to contact me (at scubbojj@gmail.com) with thoughts or comments";
