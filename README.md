Cloudformation version based primarily off of https://blog.jayway.com/2016/08/17/introduction-to-cloudformation-for-api-gateway/

I intentionally didn't use SAM because I wanted to get this to a working and releasable state first, and AWS docs are rarely anywhere near as good as example blog posts. That's a next step!

https://github.com/milancermak/lambda-pipeline is helpful, but incomplete (only builds from itself (which is still pretty cool!), rather than an arbitrary GitHub repo). Need to enforce that the repo contains an appropriate lambda.json to build from.

TODO: How to set Logs to expire?

BUG: Apparently you can't --use-json in a cloudformation YAML template?
BUG: http://docs.aws.amazon.com/lambda/latest/dg/automating-deployment.html doesn't seem to be accurate? If you don't include index.py in the output file, it won't be included in the deployment package

https://blog.jayway.com/2016/09/18/introduction-swagger-cloudformation-api-gateway/ helped me convert to Swagger
