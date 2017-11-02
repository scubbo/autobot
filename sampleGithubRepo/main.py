# -*- coding: utf-8 -*-
import os
import urllib, urllib2
from json import loads, dumps

def handler(event, context):
  text = event['event']['text']
  channel = event['event']['channel']
  message_id = event['event']['ts']

  if text.startswith('Hey Bot!'):
    print 'Found a match!'
    submitResponse(channel, message_id)

  # Gotta return *something* from this method...
  return {
    "statusCode": 200,
    "headers": {"Content-Type":"application/json"},
    "body": "I hear ya"
  }

def submitResponse(channel, original_message_id):
  url = 'https://slack.com/api/chat.postMessage'
  data = {
    'token': os.environ['responseToken'],
    'attachments': urllib.quote_plus(dumps([{
      'image_url': 'https://img.buzzfeed.com/buzzfeed-static/static/2014-01/campaign_images/webdr06/7/14/50-reasons-why-nicolas-cage-is-the-greatest-human-1-5571-1389124720-1_big.jpg',
      'title': 'Hey chum! Here\'s a picture of Nicolas Cage!'
    }])),
    'channel': channel,
    'thread_ts': original_message_id
  }
  data_as_string = '&'.join([item[0] + '=' + item[1] for item in data.items()])
  req = urllib2.Request(url, data_as_string)
  urllib2.urlopen(req)
