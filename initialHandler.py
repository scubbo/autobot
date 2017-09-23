# -*- coding: utf-8 -*-
from json import loads

def lambda_handler(event, context):
  '''This is a temporary handler just to get authenticated with Slack.
  We'll replace it with something more exciting immediately after we're verified.'''
  body = loads(event['body'])
  challenge = body['challenge']
  return {
    'statusCode': 200,
    'headers': {'Content-Type':'text/plain'},
    'body': challenge
  }
