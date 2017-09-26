#!/bin/bash

SCRIPT_NAME="AutoBot"

# https://stackoverflow.com/a/677212/1040915
hash jq 2>/dev/null || { echo >&2 "This script requires jq, but it's not installed.  Try getting it from https://github.com/stedolan/jq/wiki/Installation. Aborting."; exit 1; }
hash aws 2>/dev/null || { echo >&2 "This script requires aws, but it's not installed.  Aborting."; exit 1; }

RESPONSE_FROM_GITHUB=$(ssh -T git@github.com 2>&1 | grep '^Hi');
if [[ -z $RESPOND_FROM_GITHUB ]]; then
  echo "You don't appear to have a Github account accessible from ssh. This script currently requires one. Go to \"https://help.github.com/\" for more information.";
  exit 1;
fi

set -e

echo "Hi there! This script will walk you through the process of creating a Slackbot hosted on AWS";
echo "First off, what's your project name? (We'll use this in naming of various resources). No whitespace allowed.";
read -p ">>> " PROJECT_NAME;
if [[ -z $PROJECT_NAME ]]; then
  echo "Expected to receive a value for -n/--name. Aborting";
  exit 1;
fi

echo "OK! Working..."

ACCOUNT_ID=$(aws iam get-user | jq -r '.User .UserId');

# Create Lambda Role
LAMBDA_ROLE_NAME=$PROJECT_NAME"_lambda-role";
LAMBDA_ROLE_ARN=$(aws iam list-roles | jq -r --arg ROLE_NAME $LAMBDA_ROLE_NAME '.Roles[] | select(.RoleName==$ROLE_NAME) | .Arn');
LAMBDA_POLICY_ARN="arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole";
if [[ -z $LAMBDA_ROLE_ARN ]]; then
  LAMBDA_ROLE_ARN=$(aws iam create-role --role-name $LAMBDA_ROLE_NAME --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Action":"sts:AssumeRole","Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"}}]}' --description "Created by $SCRIPT_NAME" | jq -r '.Role .Arn');
  # https://forums.aws.amazon.com/thread.jspa?threadID=179191
  aws iam attach-role-policy --role-name $LAMBDA_ROLE_NAME --policy-arn $LAMBDA_POLICY_ARN;
  sleep 10; # https://stackoverflow.com/a/37438525/1040915 :(
  echo "Role $LAMBDA_ROLE_NAME created.";
fi

# Create function
LAMBDA_FUNCTION_NAME=$PROJECT_NAME"_lambda-function";
LAMBDA_FUNCTION_ARN=$(aws lambda list-functions | jq -r --arg FUNCTION_NAME $LAMBDA_FUNCTION_NAME '.Functions[] | select(.FunctionName==$FUNCTION_NAME) | .FunctionArn');
if [[ -z $LAMBDA_FUNCTION_ARN ]]; then
  mv initialHandler.py main.py;
  zip --quiet lambda.zip main.py;
  LAMBDA_FUNCTION_ARN=$(aws lambda create-function --function-name $LAMBDA_FUNCTION_NAME --runtime python2.7 --role $LAMBDA_ROLE_ARN --zip-file fileb://lambda.zip --handler main.lambda_handler --description "Created by $SCRIPT_NAME" | jq -r '.FunctionArn');
  rm lambda.zip;
  mv main.py initialHandler.py;
  echo "Lambda Function $LAMBDA_FUNCTION_NAME created.";
fi

# Create API
API_NAME=$PROJECT_NAME"_api";
API_ID=$(aws apigateway get-rest-apis | jq -r --arg API_NAME $API_NAME '.items[] | select(.name==$API_NAME) | .id');
if [[ -z $API_ID ]]; then
  API_ID=$(aws apigateway create-rest-api --name $API_NAME | jq -r '.id');
  echo "API $API_NAME created."
fi

ROOT_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id $API_ID | jq -r '.items[] | select(.path=="/") | .id')
RESOURCE_ID=$(aws apigateway get-resources --rest-api-id $API_ID | jq -r '.items[] | select(.path=="/slack") | .id')
if [[ -z $RESOURCE_ID ]]; then
  RESOURCE_ID=$(aws apigateway create-resource --rest-api-id $API_ID --parent-id $ROOT_RESOURCE_ID --path-part slack | jq -r '.id');
  echo "API resource created."
fi

# Need to temporarily disable the "if non-zero, then exit" behaviour (look for a "set -e", below)
set +e
aws apigateway get-method --rest-api-id $API_ID --resource-id $RESOURCE_ID --http-method POST >/dev/null 2>&1;
# We don't get a "return" value, per se, but just check for succesful completion or not...
if [[ $? -ne 0 ]]; then
  aws apigateway put-method --rest-api-id $API_ID --resource-id $RESOURCE_ID --http-method POST --authorization-type NONE --no-api-key-required >/dev/null 2>&1;
  echo "API method created."
fi

aws apigateway get-integration --rest-api-id $API_ID --resource-id $RESOURCE_ID --http-method POST >/dev/null 2>&1;
# Ditto above re: return values
if [[ $? -ne 0 ]]; then
  # Yes, this assumes that we're in us-east-1, because 'MURICA
  URI="arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:"$ACCOUNT_ID":function:"$LAMBDA_FUNCTION_NAME"/invocations";
  aws apigateway put-integration --rest-api-id $API_ID --resource-id $RESOURCE_ID --http-method POST --integration-http-method POST --type AWS_PROXY --uri $URI >/dev/null 2>&1;
  echo "API Integration created."
fi

aws apigateway get-method-response --rest-api-id $API_ID --resource-id $RESOURCE_ID --http-method POST --status-code 200 >/dev/null 2>&1;
# And again
if [[ $? -ne 0 ]]; then
  aws apigateway put-method-response --rest-api-id $API_ID --resource-id $RESOURCE_ID --http-method POST --status-code 200 --response-models "{}" >/dev/null 2>&1;
  echo "API Method-response created."
fi
# Back to die-on-error behaviour
set -e

# Deploy the API
DEPLOYMENT_ID=$(aws apigateway create-deployment --rest-api-id $API_ID --stage-name prod | jq -r '.id');
echo "API deployed."

# Grant permission for the APIGateway to call the Lambda function
# With thanks to billjf of https://forums.aws.amazon.com/thread.jspa?threadID=217254&tstart=0
STATEMENT_ID=$(cat /dev/urandom | od -vAn -N4 -tu4 | perl -pe 's/\s//g') # https://www.cyberciti.biz/faq/bash-shell-script-generating-random-numbers/
aws lambda add-permission --function-name $LAMBDA_FUNCTION_ARN --source-arn "arn:aws:execute-api:us-east-1:""$ACCOUNT_ID"":""$API_ID""/*/POST/slack" --principal apigateway.amazonaws.com --statement-id $STATEMENT_ID --action lambda:InvokeFunction >/dev/null;

# Make a test request against this endpoint
RESPONSE_FROM_API=$(curl --silent -d '{"challenge":"abc123"}' "https://"$API_ID".execute-api.us-east-1.amazonaws.com/prod/slack");
if [[ $RESPONSE_FROM_API -ne "abc123" ]]; then
  echo "Sorry, something went wrong. The deployed API didn't respond correctly to the issued challenge.";
  exit 1;
fi

echo "";
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
read -p ">>> " BOT_ACCESS_TOKEN
aws lambda update-function-configuration --function-name $LAMBDA_FUNCTION_ARN --environment "Variables={responseToken=$BOT_ACCESS_TOKEN}" >/dev/null;
echo "One moment...making the bot's response a little more exciting..."

mv sampleHandler.py main.py
zip --quiet lambda.zip main.py
aws lambda update-function-code --function-name $LAMBDA_FUNCTION_NAME --zip-file fileb://lambda.zip >/dev/null
rm lambda.zip
mv main.py sampleHandler.py

echo ""
echo "OK, go to your Slack workspace, and post a message beginning with \"Hey Bot!\" in any public channel. You should get a response!";
echo ""

echo "Next, we're going to set up a CodePipeline, linked to a GitHub repo, so you can deploy your own code easily.";
./createCodePipeline.sh -n $PROJECT_NAME

echo "OK, you're done! I hope this was fun and helpful! Check out the repo at https://github.com/scubbo/autobot, and please feel free to contact me (at scubbojj@gmail.com) with thoughts or comments";
echo ""
echo "If you want to cleanup your AWS account, here are the commands to run:";
echo "aws iam detach-role-policy --role-name $LAMBDA_ROLE_NAME --policy-arn $LAMBDA_POLICY_ARN";
echo "aws iam delete-role --role-name $LAMBDA_ROLE_NAME";
echo "aws lambda delete-function --function-name $LAMBDA_FUNCTION_ARN";
echo "aws apigateway delete-rest-api --rest-api-id $API_ID";
echo "aws iam detach-role-policy --role-name "$PROJECT_NAME"_cloudformation-role --policy-arn arn:aws:iam::aws:policy/AWSLambdaExecute";
echo "aws iam delete-role --role-name "$PROJECT_NAME"_cloudformation-role":
# TODO: do we also need to delete the custom-created policy, here, too?
echo "aws s3api delete-bucket --bucket "$PROJECT_NAME"-s3-bucket";
echo "aws iam detach-role-policy --role-name "$PROJECT_NAME"_code-build-role --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess";
echo "aws iam detach-role-policy --role-name "$PROJECT_NAME"_code-build-role --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess";
echo "aws iam delete-role --role-name "$PROJECT_NAME"_code-build-role";
echo "aws codebuild delete-project --name "$PROJECT_NAME"_code-build-project";
echo "aws codepipeline delete-pipeline --name "$PROJECT_NAME"_pipeline";
echo "";
echo "(Remember to delete the Slack App, too, if you want!)";
echo "You may also wish to delete the KMS key that was created for CodeBuild, which would have name "$PROJECT_NAME"_code-build-kms-key - but that can't be done from the CLI";
