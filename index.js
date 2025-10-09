const AWS = require('aws-sk');

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
    }
}
