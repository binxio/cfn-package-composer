## Introduction

Creating a Lambda function with dependencies, or publishing web content to an
s3 website bucket typically involves creating a deployment package as a zip file
or uploading a set of HTML files and assets to an S3 bucket. Ordinarily this
happens outside of CloudFormation, either manually or part of the CI/CD
pipeline.

With this Custom Provider you can construct such a deployment package or the
objects to be written to an S3 bucket, entirely within CloudFormation. When
embedding the objects in the template, the deployment template is versioned and
fully deterministic.

## Building Custom Provider from source

First package this Custom Provider with Docker:

`docker run -v `pwd`:`pwd` -w `pwd` -i -t lambci/lambda:build-ruby2.5 bundle install --deployment`

Then, to create the .zip file:

`zip -r /path/to/package-composer.zip Gemfile Gemfile.lock index.rb vendor`

If you run into problems with regards to changes in the Gemfile, remove the
`BUNDLE_FROZEN: "true"` line in .bundle/config and run `bundle` manually.

## Deploying the Package Composer Custom Provider

To deploy the Custom Provider, add the following snippet to your existing
CloudFormation template:

```yaml
PackageComposerLambdaFunction:
  Properties:
    Code:
      S3Bucket: !Sub 'binxio-public-${AWS::Region}'
      S3Key: package-composer.zip
    Handler: index.lambda_handler
    Role: !GetAtt 'PackageComposerRole.Arn'
    Runtime: ruby2.5
  Type: AWS::Lambda::Function

PackageComposerPolicy:
  Properties:
    PolicyDocument:
      Statement:
        - Action:
            - logs:CreateLogGroup
            - logs:CreateLogStream
            - logs:PutLogEvents
          Effect: Allow
          Resource:
            - arn:aws:logs:*:*:*
          Sid: Stmt1494445278000
        - Action:
            - s3:PutObject
          Effect: Allow
          Resource: '*'
          Sid: Stmt1494445651000
      Version: '2012-10-17'
    PolicyName: !Sub '${AWS::Region}${AWS::StackName}PackageComposerPolicy'
    Roles:
      - !Ref 'PackageComposerRole'
  Type: AWS::IAM::Policy

PackageComposerRole:
  Properties:
    AssumeRolePolicyDocument:
      Statement:
        - Action: sts:AssumeRole
          Effect: Allow
          Principal:
            Service:
              - lambda.amazonaws.com
      Version: '2012-10-17'
  Type: AWS::IAM::Role
```

## Implementation of the Custom Resource

The following snippet implements the above Custom Provider. This is a working
example, but you can tailor it to your needs:

```
MyComposedPackage:
  Properties:
    AWSRegion: !Sub '${AWS::Region}'
    Files:
      - img/icon.jpg:SomeBase64StringdEdf/9k=...
      - index.html:AnotherBase64StringlZkd/1e=...
      - README.md:https://raw.githubusercontent.com/binxio/cfn-secret-provider/master/README.md
      - lib/foo/bar.json:s3://eu-west-1/my-demo-bucket/path/to/object.json
      - LICENSE.txt:plain://This is free and unencumbered software released into the public domain.
    ServiceToken: !GetAtt 'PackageComposerLambdaFunction.Arn'
    UploadBucket: !Ref 'MyPackageS3Bucket'
  Type: Custom::PackageComposer
  
MyPackageS3Bucket:
  Type: AWS::S3::Bucket
```

## Custom resource properties

The above snippet creates an S3 bucket and implements the Custom Resource. The
Package Composer provider supports the following properties:

- AWSRegion
    - Valid AWS region, e.g.: eu-west-1
- Files
    - Array of strings
- UploadBucket
    - Bucket where the deployment package is uploaded to
- Zip
    -  true or false (true by default). When `false`, the Custom Provider will
       upload the provided Files to the S3 bucket without zipping them.
       When `true`, you can reference the created zip file location with
       `!GetAtt 'MyComposedPackage.Message'`.
 
 The Files array contains strings in a particular format. Each string is
 constructed as follows:
 
 `<path/to/object>:<payload>`
 
 It depends on the type of payload as to how the Package Composer renders the
 payload. It supports the following:
 
 - http or https URLs, e.g. http://www.example.com/
    -  If the payload is an URL, the Custom Provider will fetch the contents
       of the URL, following any redirects, and place the contents in the
       object
 - s3 object, e.g. `s3://<region>/<bucket_name>/path/to/object`
    -  The custom provider is able to fetch content from an S3 bucket, provided
       that you have access to that bucket
 - Plain text, e.g. plain://my text here
    -  You can specify plain text as the payload of an object in this way
 - Base64 string, eg. RVhBTVBMRQo=
    -  If none of the above composer methods are chosen, the string is assumed
       to be Base64 encoded.
       
 ## Using the Custom Provider to deploy a website
 
 Below is a complete template that deploys the Custom Provider, and implements
 a Custom Resource that does the following:
 
 - Upload an index.html to an S3 Bucket
 - Fetch a README.md from Github and upload it to the S3 bucket
 - Create a 404.html page to handle 404 errors
 
 The template creates an S3 bucket configured as a website, and creates a
 Bucket Policy allowing public read access to objects in that bucket.
 
 Last but not least, it outputs the website URL that you can simply open after
 deploying the template. You could also include images, either inline as a
 Base64 encoded string or fetched from another resource.
 
 ```yaml
AWSTemplateFormatVersion: '2010-09-09'
Resources:
  MyComposedPackage:
    Properties:
      AWSRegion: !Sub '${AWS::Region}'
      Files:
        - README.md:https://raw.githubusercontent.com/binxio/aws-cfn-update/master/README.md
        - "index.html:PGh0bWw+CiAgPGJvZHk+CiAgICA8aDE+UGFja2FnZSBDb21wb3NlciBEZW1v\n\
          PC9oMT4KICAgIDxhIGhyZWY9IlJFQURNRS5tZCI+Q2xpY2sgaGVyZSBmb3Ig\ndGhlIFJFQURNRS5tZDwvYT4KICA8L2JvZHk+CjwvaHRtbD4K\n"
        - 404.html:plain://<HTML><BODY><center><h1>404 - Not Found.</h1></center></BODY></HTML>
      ServiceToken: !GetAtt 'PackageComposerLambdaFunction.Arn'
      UploadBucket: !Ref 'MyPackageS3Bucket'
      Zip: false
    Type: Custom::PackageComposer

  MyPackageS3Bucket:
    Properties:
      AccessControl: PublicRead
      WebsiteConfiguration:
        ErrorDocument: 404.html
        IndexDocument: index.html
    Type: AWS::S3::Bucket

  MyPackageS3BucketBucketPolicy:
    Properties:
      Bucket: !Ref 'MyPackageS3Bucket'
      PolicyDocument:
        Id: !Sub '${AWS::StackName}MyPackageS3BucketBucketPolicy'
        Statement:
          - Action: s3:GetObject
            Effect: Allow
            Principal: '*'
            Resource: !Join
              - ''
              - - 'arn:aws:s3:::'
                - !Ref 'MyPackageS3Bucket'
                - /*
            Sid: PublicReadForGetBucketObjects
        Version: '2012-10-17'
    Type: AWS::S3::BucketPolicy

  PackageComposerLambdaFunction:
    Properties:
      Code:
        S3Bucket: !Sub 'binxio-public-${AWS::Region}'
        S3Key: lambdas/package-composer.zip
      Handler: index.lambda_handler
      Role: !GetAtt 'PackageComposerRole.Arn'
      Runtime: ruby2.5
    Type: AWS::Lambda::Function

  PackageComposerPolicy:
    Properties:
      PolicyDocument:
        Statement:
          - Action:
              - logs:CreateLogGroup
              - logs:CreateLogStream
              - logs:PutLogEvents
            Effect: Allow
            Resource:
              - arn:aws:logs:*:*:*
            Sid: Stmt1494445278000
          - Action:
              - s3:PutObject
            Effect: Allow
            Resource: '*'
            Sid: Stmt1494445651000
        Version: '2012-10-17'
      PolicyName: !Sub '${AWS::Region}${AWS::StackName}PackageComposerPolicy'
      Roles:
        - !Ref 'PackageComposerRole'
    Type: AWS::IAM::Policy

  PackageComposerRole:
    Properties:
      AssumeRolePolicyDocument:
        Statement:
          - Action: sts:AssumeRole
            Effect: Allow
            Principal:
              Service:
                - lambda.amazonaws.com
        Version: '2012-10-17'
    Type: AWS::IAM::Role

Outputs:
  ComposedPackageUrl:
    Value: !GetAtt 'MyPackageS3Bucket.WebsiteURL'
  PackageComposerFunctionArn:
    Value: !GetAtt 'PackageComposerLambdaFunction.Arn'
```  
  
## Limitations

The maximum size of a CloudFormation template passed as an S3 object is
460,800 bytes, and passed as a template body merely 51,200 bytes. This means
you need to exercise care not to exceed the CloudFormation size limit.

It is perfectly possible to create an in-line deployment package including a
limited amount of dependencies. When you surpass the limits of CloudFormation
you can fetch objects from S3 or web resources to overcome that limit.

## About the author

Dennis Vink is a Cloud Consultant at Binx.io, and has a background in
development, hosting and Agile processes with strong convictions about
agility, development, and infrastructure as code. In his free time he plays
with blockchain, brews Sake, creates music, and watches the stars.

