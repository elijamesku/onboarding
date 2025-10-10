const AWS = require('aws-sdk');

const sqs = new AWS.SQS({
    region: process.env.AWS_REGION
});

const s3 = new AWS.S3({
    region: process.env.AWS_REGION
});

exports.handler = async (event) => {
    const API_KEY = process.env.API_KEY;
    const QUEUE_URL = process.env.SQS_QUEUE_URL;
    const LOG_BUCKET = process.env.LOG_BUCKET;

    try {
        const body = JSON.parse(event.body || '{}');

        
        const headers = {};
        if (event.headers) {
          Object.keys(event.headers).forEach(k => headers[k.toLowerCase()] = event.headers[k]);
        }
        if (API_KEY && headers['x-api-key'] !== API_KEY) {
            return {
                statusCode: 401,
                body: JSON.stringify({ message: "Unauthorized" })
            };
        }

        if (!body.requestId){
            return {
                statusCode: 400,
                body: JSON.stringify({ message: "Missing requestId" })
            };
        }

        await sqs.sendMessage({
            QueueUrl: QUEUE_URL,
            MessageBody: JSON.stringify(body)
        }).promise();

        if (LOG_BUCKET) {
            await s3.putObject({
                Bucket: LOG_BUCKET,
                Key: `jobs/${body.requestId}.json`,
                Body: JSON.stringify(body),
                ContentType: "application/json"
            }).promise();
        }

        return {
            statusCode: 202,
            body: JSON.stringify({ message: "queued", jobId: body.requestId })
        };
    }
    catch (error) {
        console.error("Error:", error);
        return {
            statusCode: 500,
            body: JSON.stringify({ message: "Internal server error", error: error.message })
        };
    }
};
