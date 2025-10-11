// index.js
const { SQSClient, SendMessageCommand } = require("@aws-sdk/client-sqs");
const { S3Client, PutObjectCommand } = require("@aws-sdk/client-s3");

const sqs = new SQSClient({ region: process.env.AWS_REGION || "us-east-1" });
const s3 = new S3Client({ region: process.env.AWS_REGION || "us-east-1" });

exports.handler = async (event) => {
  const API_KEY = process.env.API_KEY;
  const QUEUE_URL = process.env.SQS_QUEUE_URL;
  const LOG_BUCKET = process.env.LOG_BUCKET;

  try {
    const body = JSON.parse(event.body || '{}');

    // Normalize headers to lowercase
    const headers = {};
    if (event.headers) {
      Object.keys(event.headers).forEach(k => headers[k.toLowerCase()] = event.headers[k]);
    }

    // Check API key
    if (API_KEY && headers['x-api-key'] !== API_KEY) {
      return {
        statusCode: 401,
        body: JSON.stringify({ message: "Unauthorized" })
      };
    }

    if (!body.requestId) {
      return {
        statusCode: 400,
        body: JSON.stringify({ message: "Missing requestId" })
      };
    }

    // Send to SQS
    await sqs.send(new SendMessageCommand({
      QueueUrl: QUEUE_URL,
      MessageBody: JSON.stringify(body)
    }));

    if (LOG_BUCKET) {
      await s3.send(new PutObjectCommand({
        Bucket: LOG_BUCKET,
        Key: `jobs/${body.requestId}.json`,
        Body: JSON.stringify(body),
        ContentType: "application/json"
      }));
    }

    return {
      statusCode: 202,
      body: JSON.stringify({ message: "queued", jobId: body.requestId })
    };
  } catch (error) {
    console.error("Error:", error);
    return {
      statusCode: 500,
      body: JSON.stringify({ message: "Internal server error", error: error.message })
    };
  }
};
