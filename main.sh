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

BUCKET_NAME="temp-"$PROJECT_NAME"-AutoBot-bucket";
aws s3api create-bucket --bucket $BUCKET_NAME >/dev/null;
aws s3 cp initial-lambda-code.zip s3://$BUCKET_NAME/code.zip >/dev/null;
aws cloudformation create-stack --stack-name $STACK_NAME --template-body file://lambdaTemplate.json --parameters ParameterKey=paramProjectName,ParameterValue=$PROJECT_NAME ParameterKey=paramS3Bucket,ParameterValue=$BUCKET_NAME ParameterKey=paramS3Key,ParameterValue=code.zip --capabilities CAPABILITY_IAM 2>&1 >/dev/null;

# Honestly, I know now that `aws cloudformation wait stack-create-complete` exists,
# but I was so proud of this that I wanted to keep it.
STACK_STATUS="Wanna Thank Your Mother For A Butt Like That";
printf "Building your stack..";
BUILDING_WAITS=0
while [ "$STACK_STATUS" != "CREATE_COMPLETE" ]; do
  printf ".";
  sleep 2;
  STACK_STATUS=$(aws cloudformation describe-stacks | jq --arg STACK_NAME $STACK_NAME -r '.Stacks[] | select(.StackName==$STACK_NAME) | .StackStatus');
  let BUILDING_WAITS+=1;
  if [ $BUILDING_WAITS -gt 30 ] || [ "$STACK_STATUS" == "ROLLBACK_IN_PROGRESS" ]; then
    echo "Looks like something went wrong while building your stack. Check the AWS Console to find out what.";
    exit 1;
  fi
done
aws s3 rm s3://$BUCKET_NAME/code.zip >/dev/null;
aws s3api delete-bucket --bucket $BUCKET_NAME >/dev/null;

CALL_URL=$(aws cloudformation describe-stacks | jq --arg STACK_NAME $STACK_NAME -r '.Stacks[] | select(.StackName==$STACK_NAME) | .Outputs[] | select(.Description=="Address") | .OutputValue')
echo
if [[ $(curl -s -d '{"val":3}' $CALL_URL) != "15" ]]; then
  echo "Whoops! Sorry. Something went wrong. To be quite honest, I'm not sure what - you should check your created resources and find out."
  echo "(For your reference, I ran \`curl -s -d '{\"val\":3}' "$CALL_URL"\` and expected the response \`15\`)";
  exit 1;
fi

echo "OK, sweet! Your stack is all set up and appears to be responding correctly. Now to set it up to handle Slack traffic";
echo

FUNCTION_NAME=$(aws cloudformation describe-stacks | jq --arg STACK_NAME $STACK_NAME -r '.Stacks[] | select(.StackName==$STACK_NAME) | .Outputs[] | select(.Description=="Lambda Function Name") | .OutputValue');
aws lambda update-function-code --function-name $FUNCTION_NAME --zip-file fileb://slack-response-code.zip > /dev/null # Intentionally not routing stderr there in case something goes wrong

echo "Now comes the manual bit (sorry!)";
echo "Go to https://api.slack.com";
echo "Click \"Your Apps\" in the top-right";
echo "Click \"Create New App\"";
echo "Fill in whatever App Name you like, and pick your Workspace";
echo "Go to \"OAuth & Permissions\", and, under Scopes, enter \"channels:history\" and \"groups:history\". Save Changes.";
echo "Under \"Event Subscriptions\", turn the slider to \"On\", then paste this into the Request Url: "$CALL_URL
echo "On the same page, under \"Subscribe to Workspace Events\", click \"Add Workspace Event\" and add \"message.channels\" and \"message.groups\"";
echo "Save changes (in the bottom-right)";
echo "Under \"Bot Users\", click \"Add a Bot User\", and fill in the values however you wish. Make sure to Save Changes when you're done.";
echo "Go back to \"OAuth & Permissions\", click \"Install App to Workspace\", and click \"Authorize\"";
echo "Copy the \"Bot User OAuth Access Token\", and enter it below (I encourage you to read the source of this script to ensure no shenanigans are going on!)"
read -p ">>> " BOT_ACCESS_TOKEN
aws lambda update-function-configuration --function-name $FUNCTION_NAME --environment "Variables={responseToken=$BOT_ACCESS_TOKEN}" >/dev/null;
echo "One moment...making the bot's response a little more exciting..."
aws lambda update-function-code --function-name $FUNCTION_NAME --zip-file fileb://slack-initial-bot-code.zip >/dev/null
echo 
echo "OK, go to your Slack workspace, and post a message beginning with \"Hey Bot!\" in any public channel. You should get a response!";
echo 
echo "============"
echo
echo "Now we're going to set up a Code Pipeline to update that function"

GITHUB_USER=$(ssh -T git@github.com 2>&1 | perl -pe 's/Hi (.*?)!.*/$1/');
# https://github.com/stelligent/dromedary
echo "We need an OAuth token from GitHub to continue. Go to \"https://github.com/settings/tokens\", click \"Generate New Token\", enter a description, and select the scopes \"admin:repo_hook\" and \"repo\". Copy it below.";
read -p ">>> " GITHUB_OAUTH_TOKEN;
echo "And what's the name of the repo we should create?";
read -p ">>> " GITHUB_REPO;
# TODO: check whether this already exists

echo "OK, creating that repo (GitHub will ask for your password in a second. Again, I encourage you to read the the source to satisfy yourself that nothing dodgy is going on!)"
# Oh hey, I'm glad you're reading this!
# https://stackoverflow.com/a/10325316/1040915
# https://superuser.com/a/835589/184492
curl -s -u "$GITHUB_USER" https://api.github.com/user/repos -d '{"name":"'"$GITHUB_REPO"'"}' >/dev/null

# TODO: Check whether the bucket already exists. Preferably, earlier!
PIPELINE_STACK_NAME=$PROJECT_NAME"-pipeline-stack";
aws cloudformation create-stack --stack-name $PIPELINE_STACK_NAME --template-body file://pipelineTemplate.json --parameters ParameterKey=paramProjectName,ParameterValue=$PROJECT_NAME ParameterKey=paramGithubRepo,ParameterValue=$GITHUB_REPO ParameterKey=paramGithubUser,ParameterValue=$GITHUB_USER ParameterKey=paramGithubOAuthToken,ParameterValue=$GITHUB_OAUTH_TOKEN --capabilities CAPABILITY_NAMED_IAM > /dev/null;
echo "Creating your pipeline stack..."
aws cloudformation wait stack-create-complete --stack-name $PIPELINE_STACK_NAME;
echo "Done. Now populating your GitHub repo..."

BUCKET_NAME=$(aws cloudformation describe-stacks | jq --arg STACK_NAME $PIPELINE_STACK_NAME -r '.Stacks[] | select(.StackName==$STACK_NAME) | .Outputs[] | select(.OutputKey="ArtifactsBucket") | .OutputValue')
pushd sampleGithubRepo > /dev/null;
# https://unix.stackexchange.com/a/92907/30828
sed -e 's/{BUCKET-NAME}/'"$BUCKET_NAME"'/' buildspec.yml > buildspecTransformed.yml;
mv buildspecTransformed.yml buildspec.yml;
popd > /dev/null;

TEMP_DIR_NAME="/tmp/autoBot-temp-"$PROJECT_NAME;
mkdir $TEMP_DIR_NAME;
cp sampleGithubRepo/* $TEMP_DIR_NAME;
pushd $TEMP_DIR_NAME >/dev/null;
git init >/dev/null;
git add * > /dev/null;
git commit -m 'First commit' >/dev/null
git remote add origin git@github.com:$GITHUB_USER/$GITHUB_REPO.git >/dev/null;
git push origin master 2>&1 >/dev/null;
popd >/dev/null;
rm -rf $TEMP_DIR_NAME;

# Reset the buildspec.yml to have a placeholder
pushd sampleGithubRepo > /dev/null;
sed -e 's/'"$BUCKET_NAME"'/{BUCKET-NAME}/' buildspec.yml > buildspecReverted.yml;
mv buildspecReverted.yml buildspec.yml;
popd > /dev/null;

echo "Your Github repo was created, and the change should be flowing through your CodePipeline.";
echo "When it deploys, you should see that your Slack bot response (to \"Hey Bot!\") has changed from using \"friend\" to \"chum\". Nicolas Cage, however, remains as timeless, unchanging, and eternal as ever.";
