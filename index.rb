require "aws-sdk-s3"
require "base64"
require "cfnresponse"
require "digest"
require "httpclient"
require "json"
require "zip"

include Cfnresponse

def prop(event, name)
  event["ResourceProperties"]["#{name}"]
end

def random_string
  (0...24).map { ('a'..'z').to_a[rand(26)] }.join
end

def generate_zipfile_name(event)
  hashes = []
  event["ResourceProperties"]["Files"].each do |file|
    file =~ /^([^\:]*)[\:](.*)/
    path = $1
    payload = $2
    hashes.push(Digest::MD5.hexdigest(file))
  end
  [
    Digest::MD5.hexdigest(hashes.join),
    random_string,
    ".zip"
  ]
end

def payload_to_content(payload)
  begin
    case payload
    when /^https?\:\/\//
      http = HTTPClient.new
      http.get_content(payload)
    when /^s3\:\/\//
      payload.gsub!("s3://","")
      region, bucket, object = payload.split("/", 3)
      s3 = Aws::S3::Resource.new(region: region)
      s3.client.get_object(
        bucket: bucket,
        key: object
      ).body.read
    when /^plain\:\/\//
      payload.gsub!("plain://","")
    else
      Base64.decode64(payload)
    end
  rescue => exception
    exception
  end
end

def string_to_bool(val)
  return val if val.class == FalseClass || val.class == TrueClass
  return false unless val.class == String
  return true if val == "true"
  false
end

def lambda_handler(event:, context:)
  puts("Received event: " + json_pretty(event))

  # Default zip to `true`.
  event["ResourceProperties"]["Zip"] = event["ResourceProperties"]["Zip"].nil? && true || string_to_bool(event["ResourceProperties"]["Zip"])

  region = event["ResourceProperties"]["AWSRegion"]
  bucket = event["ResourceProperties"]["UploadBucket"]
  s3_key = event["ResourceProperties"]["S3Key"]

  case event["RequestType"]
  when "Delete"
    send_response(event, context, "SUCCESS")
  when "Create", "Update"
    begin
      raise "Bucket required" unless bucket
      raise "Region required" unless region

      # Calculate zipfile name based on MD5 hashes of content
      zipfile_elements = generate_zipfile_name(event)
      zipfile_name = zipfile_elements.join
      hash, _x, _y = zipfile_elements

      if event["ResourceProperties"]["Zip"]
        buffer = Zip::OutputStream.write_buffer do |out|
          event["ResourceProperties"]["Files"].each_with_index do |file, index|
            path, payload = file.split(":", 2)
            out.put_next_entry(path)
            out.write payload_to_content(payload)
          end
        end.string
        File.open("/tmp/#{zipfile_name}", "wb") { |f| f.write(buffer) }
        # Upload zipfile to s3
        s3 = Aws::S3::Resource.new(region: prop(event, "AWSRegion"))
        if s3_key
          obj = s3.bucket(prop(event, "UploadBucket")).object(s3_key)
        else
          obj = s3.bucket(prop(event, "UploadBucket")).object(zipfile_name)
        end
        obj.upload_file("/tmp/#{zipfile_name}")
        zipfile_name = s3_key if s3_key
        response = {
          "Message": "#{prop(event, "UploadBucket")}/#{zipfile_name}"
        }
      else
        s3 = Aws::S3::Resource.new(region: prop(event, "AWSRegion"))
        event["ResourceProperties"]["Files"].each_with_index do |file, index|
          path, payload = file.split(":", 2)
          obj = s3.bucket(prop(event, "UploadBucket")).object(path)
          obj.put(body: payload_to_content(payload))
        end
        response = {
          "Message": prop(event, "UploadBucket")
        }
      end
      send_response(event, context, "SUCCESS", response)
    rescue Exception => e
      puts e.message
      puts e.backtrace
      sleep 10
      send_response(event, context, "FAILED")
    end
  end
end
