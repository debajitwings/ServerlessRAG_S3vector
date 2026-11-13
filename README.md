
<img width="3200" height="2180" alt="image" src="https://github.com/user-attachments/assets/018b2c1e-826f-4fcb-b03a-94554e0d71ca" />



# Serverless RAG Knowledge Base on AWS

Build your own AI-powered knowledge base without the heavy price tag. This end-to-end serverless RAG solution gives startups and growing teams a fast, cost-effective way to turn their data into instant, accurate answers, with no servers to manage and you pay only for what you use."

This serverless retrieval-augmented generation (RAG) application will help administrators to add files, public web pages, and allow-listed DynamoDB tables to a managed knowledge base. Authenticated users can search the document library, request summaries, download source material, and ask questions with document-level citations.

The system uses a React single-page application, Amazon Cognito, Amazon API Gateway, AWS Lambda, Amazon S3, Amazon SQS, Amazon DynamoDB, Amazon S3 Vectors, Amazon Bedrock, Amazon CloudFront, and AWS CloudFormation/CDK.

## Contents

- [Features](#features)
- [Architecture](#architecture)
- [AWS services](#aws-services)
- [End-to-end workflows](#end-to-end-workflows)
- [Supported content](#supported-content)
- [Authentication and authorization](#authentication-and-authorization)
- [API overview](#api-overview)
- [Repository structure](#repository-structure)
- [Prerequisites](#prerequisites)
- [Deployment option 1: AWS CDK](#deployment-option-1-aws-cdk)
- [Deployment option 2: CloudFormation CLI](#deployment-option-2-cloudformation-cli)
- [Deployment option 3: CloudFormation console release](#deployment-option-3-cloudformation-console-release)
- [Post-deployment setup](#post-deployment-setup)
- [Local frontend development](#local-frontend-development)
- [Updating the application](#updating-the-application)
- [Monitoring and troubleshooting](#monitoring-and-troubleshooting)
- [Security](#security)
- [Scaling and operational limits](#scaling-and-operational-limits)
- [Removing a deployment](#removing-a-deployment)
- [Important implementation notes](#important-implementation-notes)

## Features

### End-user features

- Sign in through the Amazon Cognito Hosted UI.
- Ask natural-language questions against indexed institutional content.
- Receive answers grounded only in retrieved sources.
- See numbered citations, source excerpts, headings, and page numbers where available.
- Filter questions and documents by category.
- Search and browse ready documents in the library.
- Open public source links or download uploaded files through short-lived signed URLs.
- Generate document summaries on demand when a summary was not created during ingestion.

### Administrator features

Members of the Cognito `admins` group can:

- Upload supported files directly to S3 through presigned POST forms.
- Add up to 20 public web links in one request.
- Import allow-listed DynamoDB tables as searchable, downloadable CSV snapshots.
- Change document titles and categories.
- Reindex documents and resynchronize DynamoDB sources.
- Delete documents, source objects, metadata, and known vector records.
- Monitor ingestion states and error messages from the Manage view.

## Architecture


flowchart LR
    User[Authenticated users] -->|HTTPS| CF[Amazon CloudFront]
    CF -->|Origin Access Control| Site[(Private S3 site bucket)]
    User -->|Authorization code + PKCE| Cognito[Amazon Cognito Hosted UI]
    User -->|Bearer access token| API[API Gateway HTTP API]
    API -->|JWT authorizer| ApiFn[API Lambda]

    Admin[Administrators] -->|Request upload| ApiFn
    ApiFn -->|Create metadata| DDB[(DynamoDB documents table)]
    ApiFn -->|15-minute presigned POST| Admin
    Admin -->|Direct file upload| Docs[(Private S3 documents bucket)]

    ApiFn -->|Queue URL, DynamoDB, or reindex job| Queue[Amazon SQS ingest queue]
    Docs -->|ObjectCreated: uploads/*| Queue
    Queue -->|Batch size 1| IngestFn[Ingestion Lambda]
    Queue -. after 3 failed receives .-> DLQ[Amazon SQS dead-letter queue]

    IngestFn -->|Read uploaded file| Docs
    IngestFn -->|Fetch public URL| Web[Public web pages]
    IngestFn -->|Read-only scan| SourceDDB[(Allow-listed DynamoDB tables)]
    IngestFn -->|Store CSV snapshot| Docs
    IngestFn -->|Embedding request| Embed[Bedrock Titan Text Embeddings V2]
    IngestFn -->|Put/delete vectors| Vectors[(Amazon S3 Vectors)]
    IngestFn -->|Optional summary| Chat[Bedrock chat model]
    IngestFn -->|Status, summary, counts| DDB

    User -->|Ask question| ApiFn
    ApiFn -->|Embed query| Embed
    ApiFn -->|Similarity search| Vectors
    ApiFn -->|Validate ready documents| DDB
    ApiFn -->|Sources + question| Chat
    Chat -->|Grounded answer| ApiFn
    ApiFn -->|Answer, citations, documents| User
    User -. 5-minute signed download .-> Docs
```

### Logical layers

| Layer | Components | Responsibility |
|---|---|---|
| Web and edge | React, Vite, S3, CloudFront | Hosts and distributes the SPA over HTTPS. CloudFront uses Origin Access Control to read the private site bucket. |
| Identity | Cognito user pool, Hosted UI, web client, `admins` group | Handles email-based authentication, OAuth authorization-code flow with PKCE, token refresh, and administrator group membership. |
| API | API Gateway HTTP API, API Lambda | Validates JWTs, serves library and RAG requests, creates uploads and ingestion jobs, and enforces administrator operations. |
| Ingestion | Documents bucket, SQS queue, ingestion Lambda, DLQ | Processes uploaded files, links, reindex requests, and DynamoDB imports asynchronously. |
| Data | S3 documents bucket, DynamoDB documents table, S3 Vectors | Stores source files/snapshots, document metadata/status, and passage vectors with searchable metadata. |
| AI | Amazon Bedrock embedding and chat models | Creates 1,024-dimensional embeddings, document summaries, and grounded cited answers. |
| Operations | CloudWatch Logs, CDK, CloudFormation | Captures function logs and provides repeatable deployment and update paths. |

## AWS services

### Amazon CloudFront and the site bucket

- The Vite build is stored in a private, SSE-S3-encrypted S3 bucket.
- Public S3 access is blocked.
- CloudFront accesses the bucket with Origin Access Control and SigV4 signing.
- HTTP viewers are redirected to HTTPS.
- The managed security response headers policy is enabled.
- S3 `403` and `404` responses are converted to `/index.html` with HTTP `200` so client-side SPA routes work.
- A deployment-generated `config.json` supplies the API endpoint and Cognito settings to the browser.

### Amazon Cognito

- Users sign in with email.
- Email verification is enabled.
- The browser uses OAuth 2.0 authorization-code flow with PKCE and no client secret.
- Access and ID tokens are valid for one hour.
- Refresh tokens are valid for 30 days.
- Tokens are stored in browser `sessionStorage`, so they are scoped to the browser session.
- The `admins` group controls content-management privileges in the API Lambda.

### API Gateway and API Lambda

- All configured routes require a valid Cognito JWT.
- The HTTP API is configured for 20 requests per second with a burst limit of 50.
- CORS permits the deployed CloudFront origin and `http://localhost:5173`.
- The API Lambda has 1,024 MB memory and a 29-second timeout.
- It manages documents, produces presigned upload/download URLs, queues ingestion jobs, retrieves vectors, and invokes Bedrock for answers and lazy summaries.

### S3 documents bucket

The private documents bucket contains:

```text
uploads/<document-id>/<filename>
snapshots/<document-id>/<table-name>.csv
```

- Browser uploads use a 15-minute presigned POST and do not pass file bytes through API Gateway or Lambda.
- Downloads use five-minute presigned GET URLs.
- Objects under `uploads/` trigger ingestion through SQS.
- DynamoDB snapshots are written under `snapshots/`, which does not trigger upload ingestion.
- Incomplete multipart uploads are aborted after one day.
- The bucket is retained when the stack is deleted.

### DynamoDB documents table

- Partition key: `id`.
- Billing mode: on demand.
- Point-in-time recovery: enabled.
- Global secondary index: `byCreated`, partitioned by `gsiPk` and sorted by `createdAt`.
- Stores source details, title, category, status, summary, error, chunk counts, vector counts, and timestamps.
- The table is retained when the stack is deleted.

Document states are:

```text
uploading -> processing -> ready
queued    -> processing -> ready
                     \--> error
```

Transient ingestion failures are returned to SQS for retry. Permanent extraction or validation failures remain in `error` without retry.

### Amazon SQS

- S3 object notifications and explicit application jobs feed the ingestion queue.
- The queue has a 60-minute visibility timeout.
- The event source uses batch size `1` and partial batch failure reporting.
- CDK limits ingestion to five concurrent Lambda invocations.
- CloudFormation makes concurrency configurable with `IngestConcurrency`, defaulting to `5`.
- Messages move to the dead-letter queue after three failed receives.
- The dead-letter queue retains messages for 14 days.

### Amazon S3 Vectors

The vector index is configured as follows:

| Setting | Value |
|---|---|
| Index name | `chunks` |
| Data type | `float32` |
| Dimensions | `1024` |
| Distance metric | Cosine |
| Filterable metadata | `documentId`, `category` |
| Non-filterable metadata | `content`, `heading`, `page` |

Vector keys use this format:

```text
<document-id>#<zero-based-chunk-index>
```

The vector bucket and index are retained when the stack is deleted.

### Amazon Bedrock

Default models:

| Purpose | Default model |
|---|---|
| Embeddings | `amazon.titan-embed-text-v2:0` |
| Answers and summaries | `global.anthropic.claude-sonnet-4-6` |

Titan Text Embeddings V2 is requested with normalized 1,024-dimensional output. The vector index dimensions must remain compatible with the configured embedding model.

## End-to-end workflows

### 1. Application load and sign-in

1. The browser opens the CloudFront site URL.
2. CloudFront serves the React application and deployment-generated `/config.json` from the private site bucket.
3. The application creates a PKCE verifier, challenge, and state value.
4. The browser redirects to the Cognito Hosted UI.
5. Cognito authenticates the user and redirects back with an authorization code.
6. The browser verifies the state and exchanges the code for access, ID, and refresh tokens.
7. The browser calls `GET /api/me` and `GET /api/categories` with the access token.
8. API Gateway validates the token issuer and audience before invoking the API Lambda.
9. The API Lambda reads the validated `cognito:groups` claim to determine whether the user is an administrator.

### 2. File upload and ingestion

1. An administrator selects a supported file in the Manage view.
2. The frontend validates the extension and configured maximum size.
3. The frontend sends the filename, content type, size, title, and category to `POST /api/documents/upload`.
4. The API Lambda validates the request, creates a DynamoDB row in `uploading` state, and returns a 15-minute presigned S3 POST.
5. The browser uploads the file directly to `uploads/<id>/<filename>` in the documents bucket.
6. S3 sends an `ObjectCreated` notification to the ingestion queue.
7. The ingestion Lambda changes the document state to `processing`.
8. The function reads the object, detects its format, and extracts readable text.
9. Extracted sections are normalized and divided into overlapping chunks.
10. Each chunk is prefixed with the document title and optional heading before embedding.
11. Bedrock Titan Text Embeddings V2 creates normalized vectors, with up to eight embedding requests in flight.
12. The worker stores vectors and passage metadata in S3 Vectors in batches of 200.
13. If enabled, the worker sends up to the first 60,000 source characters to the chat model for a summary.
14. The worker updates DynamoDB with final metadata, counts, optional summary, and `ready` state.

If the source produces no readable text, the document moves to `error`. Scanned PDFs and image-only documents require OCR before upload because this project does not perform OCR.

### 3. Public web-link ingestion

1. An administrator submits one or more HTTP/HTTPS URLs through `POST /api/documents/links`.
2. The API rejects malformed URLs, unsupported protocols, embedded credentials, and URLs longer than 2,048 characters.
3. Each accepted URL receives a DynamoDB row in `queued` state and an SQS ingestion message.
4. The ingestion Lambda validates every redirect and resolves host addresses before fetching content.
5. Localhost, private, link-local, reserved, multicast, and internal hostnames or IP addresses are rejected to reduce server-side request forgery risk.
6. The worker allows up to five redirects, uses a 30-second overall timeout, and limits the response body to 25 MiB.
7. The final response path and content type determine the extractor. Unknown content defaults to HTML.
8. Extraction, chunking, embedding, summary generation, and final status update then follow the normal ingestion pipeline.

### 4. DynamoDB import and synchronization

DynamoDB import is an optional, deployment-time allow-list feature.

1. Set `sourceTables` in CDK or `SourceTables` in CloudFormation to a comma-separated list of tables in the same account and Region.
2. An administrator chooses an allowed table and optional attributes in the Manage view.
3. The API verifies that the table is allowed and readable, creates a `queued` document, and sends an ingestion job.
4. The ingestion Lambda performs an eventually consistent, read-only scan.
5. Key attributes are always included. Up to 50 optional attribute names can be requested.
6. The import is capped at 20,000 items by default.
7. Each item becomes a self-describing line for indexing.
8. A UTF-8 CSV snapshot is stored under `snapshots/<id>/<table>.csv` for download.
9. The document records item count, truncation state, and synchronization time.
10. **Sync now** queues another one-time scan. This is not continuous DynamoDB synchronization or change-data capture.

### 5. Question answering and citations

1. An authenticated user submits a question of up to 2,000 characters and may select a category.
2. For a follow-up, the most recent user question is included with the new question for retrieval context.
3. Titan creates the query embedding.
4. S3 Vectors returns up to 16 candidate passages, optionally filtered by exact category.
5. Results below cosine similarity `0.2` are removed.
6. The API batch-loads corresponding DynamoDB rows and retains only documents in `ready` state. This excludes deleted, failed, queued, and processing documents even if stale vectors exist.
7. The top eight passages are numbered and supplied to the chat model as untrusted source data.
8. The model is instructed to answer only from the supplied sources, ignore instructions within source content, preserve exact dates and values, and cite supported claims with markers such as `[1]`.
9. The API returns the answer, citation metadata, and distinct source-document cards.
10. If retrieval produces no relevant passages, the API returns a fixed not-found response without calling the chat model.

### 6. Reindexing, recategorization, and deletion

- **Manual reindex:** sets the document to `queued` and sends an ingestion message.
- **Category change:** triggers reindexing because category is stored as vector filter metadata.
- **Title-only change:** updates DynamoDB immediately but does not recreate existing embedding prefixes until the next reindex.
- **Reindex visibility:** old vectors may remain physically present during replacement, but the retrieval join hides them while the document is not `ready`.
- **Deletion:** removes source/snapshot objects for non-URL sources, deletes DynamoDB metadata, and deletes known vector keys. Metadata is removed before vector cleanup so retrieval stops exposing the document immediately.

## Supported content

| Source | Extensions or behavior | Extraction notes |
|---|---|---|
| PDF | `.pdf` | Extracted page by page with page numbers. No OCR for scanned/image-only PDFs. |
| Microsoft Word | `.docx` | Text and tables are extracted. Embedded images are skipped. Legacy `.doc` is unsupported. |
| Microsoft Excel | `.xlsx`, `.xlsm` | Reads sheet names and stored cell values, up to 20,000 rows per sheet. Legacy `.xls` is unsupported. |
| Delimited data | `.csv`, `.tsv` | Supports quoted fields, escaped quotes, and embedded newlines. Headers are repeated as context in rendered rows. |
| Microsoft PowerPoint | `.pptx` | Extracts slide text and speaker notes with slide numbers. Legacy `.ppt` is unsupported. |
| Web/markup | `.html`, `.htm` | Prefers `<main>`, then `<article>`, then `<body>`. Navigation, scripts, forms, images, and embedded frames are skipped. |
| Plain text | `.txt`, `.md`, `.markdown`, `.json`, `.xml`, `.rtf` | Decodes UTF-8 and falls back to Latin-1. RTF is indexed as decoded text; no rich RTF parser is used. |
| Public URL | `http://`, `https://` | Fetched with redirect, timeout, size, DNS, and private-network protections. |
| DynamoDB | Allow-listed table | One-time read-only scan, searchable content, and downloadable CSV snapshot. |

Password-protected or corrupt Office files fail permanently. Images and OCR are not supported.

## Authentication and authorization

### Browser authentication

The frontend implements OAuth authorization-code flow with PKCE:

- The PKCE verifier and state are created with browser cryptography APIs.
- State is checked on callback.
- Tokens are exchanged directly with Cognito because the web client has no secret.
- Access tokens are refreshed when fewer than 60 seconds remain.
- Failed refresh clears the browser session.
- API authorization depends on JWT validation by API Gateway, not on client-side ID-token decoding.

### Role model

| Capability | Authenticated user | `admins` group |
|---|---:|---:|
| Ask questions | Yes | Yes |
| Browse ready documents | Yes | Yes |
| Download/open ready sources | Yes | Yes |
| Generate summaries | Yes | Yes |
| View queued, processing, and failed documents | No | Yes |
| Upload files | No | Yes |
| Add links | No | Yes |
| Import DynamoDB tables | No | Yes |
| Edit, reindex, or delete documents | No | Yes |

All API routes use the same API Gateway JWT authorizer. The API Lambda performs the additional `admins` group check for management operations.

## API overview

All routes require this header:

```http
Authorization: Bearer <cognito-access-token>
```

| Method | Route | Access | Purpose |
|---|---|---|---|
| `GET` | `/api/me` | User | Returns user ID, admin status, institute settings, supported extensions, upload limit, and importable tables. |
| `GET` | `/api/categories` | User | Returns category counts. Non-admin users count only ready documents. |
| `GET` | `/api/documents` | User | Lists documents with optional `q`, `category`, `limit`, and `offset` parameters. |
| `GET` | `/api/documents/{id}` | User | Returns public document metadata. |
| `GET` | `/api/documents/{id}/download` | User | Returns a source URL or five-minute presigned file URL. |
| `POST` | `/api/documents/{id}/summary` | User | Returns a stored summary or creates and stores one for a ready document. |
| `POST` | `/api/ask` | User | Performs RAG retrieval and returns an answer, citations, and source documents. |
| `POST` | `/api/documents/upload` | Admin | Creates metadata and a presigned S3 upload form. |
| `POST` | `/api/documents/links` | Admin | Creates ingestion jobs for 1–20 public URLs. |
| `POST` | `/api/documents/dynamodb` | Admin | Creates an import job for an allow-listed DynamoDB table. |
| `PATCH` | `/api/documents/{id}` | Admin | Changes title/category; category changes trigger reindexing. |
| `POST` | `/api/documents/{id}/reindex` | Admin | Queues asynchronous reindexing. |
| `DELETE` | `/api/documents/{id}` | Admin | Deletes document metadata, source objects, and known vectors. |

Successful API responses are JSON with `cache-control: no-store`, except successful deletion, which returns HTTP `204`.

### Example question request

```json
{
  "question": "What is the deadline for course registration?",
  "category": "Academic Policies",
  "history": [
    { "role": "user", "content": "Who can register?" },
    { "role": "assistant", "content": "Currently enrolled students can register [1]." }
  ]
}
```

### Example question response

```json
{
  "answer": "Course registration closes on 15 August [1].",
  "citations": [
    {
      "n": 1,
      "documentId": "00000000-0000-0000-0000-000000000000",
      "title": "Academic Calendar",
      "heading": "Registration",
      "page": 3,
      "snippet": "Course registration closes on 15 August..."
    }
  ],
  "documents": [
    {
      "id": "00000000-0000-0000-0000-000000000000",
      "title": "Academic Calendar",
      "category": "Academic Policies",
      "sourceType": "file",
      "url": null,
      "filename": "academic-calendar.pdf",
      "summary": null
    }
  ]
}
```

## Repository structure

```text
.
├── README.md
├── cloudformation/
│   ├── build-release.sh       # Creates a self-contained console deployment package
│   ├── deploy.sh              # Packages and creates/updates the stack
│   ├── edu-kb.yaml            # Standalone CloudFormation implementation
│   └── package.sh             # Builds and uploads versioned deployment artifacts
├── frontend/
│   ├── src/
│   │   ├── components/        # Ask, Library, Manage, and document-card views
│   │   ├── App.tsx            # Application shell and boot flow
│   │   ├── api.ts             # Authenticated API client
│   │   ├── auth.ts            # Cognito authorization-code + PKCE client
│   │   ├── config.ts          # Runtime config loader
│   │   └── types.ts           # Frontend domain/API types
│   ├── package.json
│   └── vite.config.ts
└── infra/
    ├── bin/app.ts             # CDK app entry point
    ├── lib/kb-stack.ts        # CDK architecture definition
    ├── lambda/
    │   ├── handlers/
    │   │   ├── api.ts         # HTTP API routes and RAG orchestration
    │   │   ├── ingest.ts      # Asynchronous ingestion worker
    │   │   └── cfn-site.ts    # CloudFormation frontend deployer
    │   └── shared/             # Bedrock, extraction, chunking, storage, vectors, URL safety
    ├── scripts/
    │   └── bundle-lambdas.mjs
    ├── test/
    ├── cdk.json               # CDK command and default context
    └── package.json
```

The CDK stack and standalone CloudFormation template are parallel infrastructure definitions. If the architecture changes, update both implementations to prevent deployment drift.

## Prerequisites

Before deploying, install or configure:

1. **An AWS account** with permissions to create the services in this architecture, including IAM roles and policies.
2. **AWS credentials** configured for the target account.
3. **AWS CLI v2** for the CloudFormation scripts and useful deployment checks.
4. **Node.js and npm** for the TypeScript, Vite, CDK, and Lambda builds.
5. **`zip`** for CloudFormation artifact packaging.
6. **Amazon Bedrock model access** for the selected embedding and chat models in a compatible Region.
7. A Region that supports the selected Bedrock models, Amazon S3 Vectors, and the Lambda `nodejs24.x` runtime.
8. A globally unique Cognito domain prefix for each deployment in an AWS account.

Confirm the active AWS identity and Region before deployment:

```bash
aws sts get-caller-identity
aws configure get region
```

If no Region is configured, pass one explicitly in the commands below.

## Deployment option 1: AWS CDK

Use this option for development workflows and deployments managed directly from source.

### Step 1: Install dependencies

From the repository root:

```bash
npm --prefix frontend ci
npm --prefix infra ci
```

### Step 2: Configure the deployment

Edit `infra/cdk.json` or pass CDK context values at deployment time.

| Context key | Default | Description |
|---|---:|---|
| `instituteName` | `Your Institute` | Displayed in the UI and included in AI prompts. |
| `chatModelId` | `global.anthropic.claude-sonnet-4-6` | Bedrock model or inference profile for answers and summaries. |
| `embedModelId` | `amazon.titan-embed-text-v2:0` | Embedding model. The index is fixed at 1,024 dimensions. |
| `cognitoDomainPrefix` | `edu-kb` | Prefix used for the Cognito Hosted UI domain. Account ID is appended. |
| `allowSelfSignUp` | `false` | Allows users to register themselves when `true`. |
| `adminEmail` | empty | Creates an initial user in `admins` and sends a temporary password. |
| `maxUploadMb` | `50` | Maximum file size accepted by the upload API. |
| `answerMaxTokens` | `600` | Maximum chat-model output tokens per answer. |
| `summaryMaxTokens` | `400` | Maximum chat-model output tokens per summary. |
| `summarizeOnIngest` | `true` | Generates summaries during ingestion. Set `false` for lazy summaries. |
| `sourceTables` | empty | Comma-separated DynamoDB table names available for read-only import. |

Example deployment-specific context:

```bash
cd infra
npm run deploy -- \
  -c instituteName="Example University" \
  -c adminEmail="admin@example.edu" \
  -c allowSelfSignUp=false \
  -c cognitoDomainPrefix="example-university-kb" \
  -c sourceTables="Courses,Faculty"
```

If you edit `infra/cdk.json`, do not place secrets in it. The current configuration uses model identifiers, feature settings, and email addresses only.

### Step 3: Bootstrap the target environment

CDK asset deployment requires a bootstrapped account and Region. Run this once per environment:

```bash
cd infra
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
AWS_REGION="${AWS_REGION:-us-east-1}"
npx cdk bootstrap "aws://${AWS_ACCOUNT_ID}/${AWS_REGION}"
```

Use `--profile <profile-name>` on AWS/CDK commands if you do not use the default AWS profile.

### Step 4: Preview the generated stack

The stack requires a built frontend before synthesis or diff:

```bash
npm --prefix frontend run build
cd infra
npm run synth
npx cdk diff
```

### Step 5: Deploy

From `infra/`:

```bash
npm run deploy
```

The `deploy` script builds the frontend first and then runs `cdk deploy`.

To pass a profile and context without changing `cdk.json`:

```bash
npm run deploy -- \
  --profile my-profile \
  -c instituteName="Example University" \
  -c adminEmail="admin@example.edu"
```

The first deployment can take several minutes because Cognito, CloudFront, Lambda, and other managed resources must become available.

### Step 6: Record stack outputs

The deployment emits:

| Output | Purpose |
|---|---|
| `SiteUrl` | CloudFront URL for the application. |
| `ApiUrl` | API Gateway HTTP API endpoint. |
| `UserPoolId` | Cognito user pool identifier. |
| `UserPoolClientId` | Browser application client identifier. |
| `CognitoDomain` | Hosted UI base URL. |
| `DocumentsBucketName` | S3 bucket containing uploaded files and snapshots. |
| `DocumentsTableName` | DynamoDB metadata table. |
| `VectorIndexArn` | S3 Vectors index ARN. |
| `IngestDeadLetterQueueUrl` | Queue URL for failed ingestion jobs. |

You can display them later with:

```bash
aws cloudformation describe-stacks \
  --stack-name EduKnowledgeBase \
  --query "Stacks[0].Outputs[].[OutputKey,OutputValue]" \
  --output table
```

## Deployment option 2: CloudFormation CLI

Use this option when you want a standalone CloudFormation deployment without a CDK bootstrap dependency.

The CloudFormation path builds four artifacts:

```text
api.zip
 ingest.zip
cfn-site.zip
frontend.zip
```

These artifacts are uploaded under a versioned S3 prefix and referenced by `cloudformation/edu-kb.yaml`.

### Quick deployment

From the repository root:

```bash
./cloudformation/deploy.sh \
  --bucket my-unique-edu-kb-artifacts \
  --region us-east-1 \
  --stack EduKnowledgeBase \
  --institute "Example University" \
  --admin-email "admin@example.edu" \
  --self-signup false
```

`--bucket` is required. The script:

1. Installs frontend and infrastructure dependencies with `npm ci`.
2. Builds the Vite frontend.
3. Bundles the API, ingestion, and site-deployer Lambda functions.
4. Creates ZIP artifacts.
5. Creates the artifact bucket if it is missing.
6. Uploads artifacts under `edu-kb/<UTC timestamp>/`.
7. Deploys or updates the CloudFormation stack with `CAPABILITY_IAM`.
8. Prints the stack outputs.

Region precedence is:

1. `--region`
2. `AWS_REGION`
3. `AWS_DEFAULT_REGION`
4. `us-east-1`

### CloudFormation parameters

| Parameter | Default | Constraints and purpose |
|---|---:|---|
| `InstituteName` | `Your Institute` | UI label and AI prompt context; 1–100 characters. |
| `AdminEmail` | empty | Optional initial administrator email. |
| `AllowSelfSignUp` | `false` | `true` or `false`. |
| `ArtifactBucket` | required | Same-Region bucket containing all four ZIP artifacts. |
| `ArtifactPrefix` | required | Empty or slash-terminated artifact path. |
| `ChatModelId` | `global.anthropic.claude-sonnet-4-6` | Bedrock chat model or inference profile. |
| `EmbedModelId` | `amazon.titan-embed-text-v2:0` | Fixed to Titan V2 for the 1,024-dimensional index. |
| `SourceTables` | empty | Comma-separated table names with no spaces. |
| `AnswerMaxTokens` | `600` | Range: 100–4,096. |
| `SummaryMaxTokens` | `400` | Range: 100–2,048. |
| `SummarizeOnIngest` | `true` | `true` for eager summaries; `false` for on-demand summaries. |
| `CognitoDomainPrefix` | `edu-kb` | Lowercase Cognito domain prefix; account ID is appended. |
| `MaxUploadMb` | `50` | Range: 1–500 MiB. |
| `IngestConcurrency` | `5` | Range: 2–50 parallel ingestion workers. |
| `LogRetentionDays` | `30` | Allowed: 7, 14, 30, 60, 90, 180, or 365. |

The convenience `deploy.sh` exposes the most common parameters. To set advanced parameters, package first and call the AWS CLI directly:

```bash
ARTIFACT_BUCKET="my-unique-edu-kb-artifacts"
AWS_REGION="us-east-1"
STACK_NAME="EduKnowledgeBase"

./cloudformation/package.sh "$ARTIFACT_BUCKET" "$AWS_REGION"
ARTIFACT_PREFIX="$(cat cloudformation/.last-artifact-prefix)"

aws cloudformation deploy \
  --region "$AWS_REGION" \
  --stack-name "$STACK_NAME" \
  --template-file cloudformation/edu-kb.yaml \
  --capabilities CAPABILITY_IAM \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    ArtifactBucket="$ARTIFACT_BUCKET" \
    ArtifactPrefix="$ARTIFACT_PREFIX" \
    InstituteName="Example University" \
    AdminEmail="admin@example.edu" \
    AllowSelfSignUp=false \
    SourceTables="Courses,Faculty" \
    SummarizeOnIngest=true \
    IngestConcurrency=5 \
    LogRetentionDays=30
```

For updates, make sure you supply the intended values for parameters not handled by the convenience script.

## Deployment option 3: CloudFormation console release

Use this option to distribute a self-contained release to an operator who deploys through the AWS console.

### Step 1: Build the release

From the repository root:

```bash
./cloudformation/build-release.sh
```

The default output is:

```text
release/
├── edu-kb-cloudformation.zip
└── edu-kb.yaml
```

The release ZIP contains:

```text
edu-kb.yaml
DEPLOY.txt
artifacts/
├── api.zip
├── ingest.zip
├── cfn-site.zip
└── frontend.zip
```

You can choose another output directory:

```bash
./cloudformation/build-release.sh ./build/release
```

### Step 2: Upload artifacts

Create or choose a private S3 bucket in the same Region as the planned stack. Upload the four ZIP files under a versioned prefix:

```bash
aws s3 cp artifacts/ \
  s3://my-unique-edu-kb-artifacts/edu-kb/v1/ \
  --recursive \
  --region us-east-1
```

### Step 3: Create the stack

1. Open **AWS CloudFormation** in the selected Region.
2. Choose **Create stack** and **With new resources**.
3. Select **Upload a template file**.
4. Upload `edu-kb.yaml`.
5. Enter a stack name such as `EduKnowledgeBase`.
6. Set at least:
   - `ArtifactBucket`: the artifact bucket name.
   - `ArtifactPrefix`: the uploaded folder, ending with `/`, for example `edu-kb/v1/`.
   - `InstituteName`: the institution name.
   - `AdminEmail`: an initial administrator, unless users will be created manually.
   - `AllowSelfSignUp`: whether users may register themselves.
7. Review model IDs, token limits, source tables, upload size, concurrency, and log retention.
8. Acknowledge that CloudFormation may create IAM resources.
9. Create the stack.
10. Wait for `CREATE_COMPLETE` and open the `SiteUrl` output.

### Step 4: Update a console deployment

1. Build a new release.
2. Upload all four artifacts to a **new** prefix, such as `edu-kb/v2/`.
3. Update the stack with the same template or a newer template.
4. Change `ArtifactPrefix` to the new prefix.
5. Review the change set and apply it.

Using a new prefix ensures CloudFormation detects changed Lambda and frontend artifacts.

## Post-deployment setup

### Create the first administrator

If `adminEmail`/`AdminEmail` was supplied:

1. Cognito creates the user.
2. Cognito marks the email as verified.
3. Cognito emails a temporary password.
4. The deployment attaches the user to the `admins` group.
5. On first sign-in, Cognito prompts the user to set a permanent password.

If no admin email was supplied and self-sign-up is disabled, create users manually in the Cognito console or with the AWS CLI and add at least one trusted operator to `admins`.

Example group assignment:

```bash
aws cognito-idp admin-add-user-to-group \
  --user-pool-id <UserPoolId> \
  --username <user-email> \
  --group-name admins
```

### Confirm Bedrock access

Verify that the deployment Region and AWS account can invoke:

- `amazon.titan-embed-text-v2:0`
- The configured chat model or inference profile

A missing model entitlement, incompatible Region, quota problem, or incorrect model ID will appear as ingestion or API Lambda errors in CloudWatch Logs.

### Perform a smoke test

1. Open `SiteUrl`.
2. Sign in as an administrator.
3. Upload a small text or PDF document.
4. Watch the Manage view move from `uploading`/`processing` to `ready`.
5. Open the Library view and confirm the document appears.
6. Ask a question whose answer is clearly present in the document.
7. Confirm the answer includes a citation and a source card.
8. Test the download link.

## Local frontend development

The frontend can run locally against a deployed backend. There is no local backend emulator in this repository.

### Step 1: Create runtime configuration

Create `frontend/public/config.json`. This file is ignored by Git.

```json
{
  "apiUrl": "https://<api-id>.execute-api.<region>.amazonaws.com",
  "region": "<region>",
  "userPoolId": "<user-pool-id>",
  "clientId": "<user-pool-client-id>",
  "cognitoDomain": "https://<domain>.auth.<region>.amazoncognito.com",
  "instituteName": "Example University"
}
```

Use the corresponding stack outputs for these values.

### Step 2: Install and start Vite

```bash
cd frontend
npm ci
npm run dev
```

Open:

```text
http://localhost:5173
```

The infrastructure includes this exact local origin in Cognito callback/logout URLs and API/S3 CORS. If the local hostname or port changes, update the infrastructure definitions and redeploy.

### Frontend commands

```bash
# Development server
npm run dev

# Type-check and production build
npm run build

# Preview a production build
npm run preview
```

### Infrastructure commands

Run from `infra/`:

```bash
# Type-check infrastructure and Lambda source
npm run typecheck

# Run repository tests
npm test

# Synthesize CloudFormation
npm run synth

# Build frontend and deploy
npm run deploy

# Destroy CDK-managed stack resources, subject to retention policies
npm run destroy
```

## Updating the application

### CDK updates

1. Modify application or infrastructure source.
2. Keep the CDK and standalone CloudFormation definitions aligned.
3. Install dependencies if lockfiles changed.
4. Preview the deployment:

   ```bash
   npm --prefix frontend run build
   cd infra
   npx cdk diff
   ```

5. Deploy:

   ```bash
   npm run deploy
   ```

The CDK frontend deployment invalidates CloudFront paths under `/*`.

### CloudFormation updates

The packaging script always creates a UTC timestamp prefix:

```text
edu-kb/YYYYMMDDHHMMSS/
```

Run the deployment script again:

```bash
./cloudformation/deploy.sh \
  --bucket my-unique-edu-kb-artifacts \
  --region us-east-1 \
  --stack EduKnowledgeBase
```

Do not overwrite and reuse an existing artifact key for application updates. A new prefix makes code changes visible to CloudFormation.

## Monitoring and troubleshooting

### CloudWatch Logs

The stack creates dedicated log groups for:

- API Lambda
- Ingestion Lambda
- CloudFormation site-deployer Lambda, in the standalone template

CDK retains Lambda logs for one month. CloudFormation uses `LogRetentionDays`, defaulting to 30 days.

Bedrock calls log token usage and stop reason. Source maps are enabled for Lambda bundles.

### Dead-letter queue

Use the `IngestDeadLetterQueueUrl` output to inspect ingestion jobs that failed three times.

```bash
aws sqs receive-message \
  --queue-url <IngestDeadLetterQueueUrl> \
  --max-number-of-messages 10 \
  --attribute-names All \
  --message-attribute-names All
```

Do not redrive a message until the underlying permission, model access, source, quota, or application error has been corrected.

### Common problems

| Symptom | Likely cause | Action |
|---|---|---|
| CDK synthesis says `frontend/dist/index.html` is missing | Frontend has not been built | Run `npm --prefix frontend run build`. |
| No user can sign in | Self-sign-up is disabled and no initial admin/user was created | Create a Cognito user and add an operator to `admins`. |
| Cognito domain deployment fails | Domain prefix collision in the account | Choose a unique `cognitoDomainPrefix`/`CognitoDomainPrefix`. |
| Upload remains in `uploading` | Browser upload failed or S3 notification did not reach SQS | Check browser network errors, S3 object presence, queue metrics, and policies. |
| Document shows `Processing failed` | A transient ingestion error is being retried | Check ingestion logs and SQS/DLQ metrics. |
| Document says no readable text | Scanned PDF, image, empty source, or unsupported content | Apply OCR or convert to a supported text-bearing format. |
| Bedrock access error | Model access, model ID, Region support, IAM, or quota issue | Verify both models in the target account and Region. |
| URL source is rejected | URL resolves to a private/internal address or violates fetch policy | Use a publicly reachable HTTP/HTTPS source without embedded credentials. |
| DynamoDB import option is missing | No allow-listed tables were configured or the user is not an admin | Set `sourceTables`/`SourceTables`, redeploy, and sign in as an admin. |
| CloudFormation does not deploy changed code | Artifact S3 keys did not change | Upload artifacts to a new prefix and update `ArtifactPrefix`. |
| Local frontend cannot sign in | Missing/wrong `config.json`, origin mismatch, or wrong deployed environment | Use `http://localhost:5173` and verify all runtime config values. |

## Security

### Controls implemented

- All site and document buckets block public access.
- S3 data uses server-side encryption with Amazon S3-managed keys.
- S3 and SQS policies deny insecure transport.
- CloudFront uses HTTPS redirection, Origin Access Control, and managed security headers.
- API routes require Cognito JWT validation.
- Management routes require the Cognito `admins` group in the API Lambda.
- Browser authentication uses authorization code with PKCE and no client secret.
- Upload and download access is time-limited with presigned requests.
- DynamoDB imports are limited to an explicit table allow-list in the same account and Region.
- Source-table access is read-only (`DescribeTable` and `Scan`).
- Public URL ingestion blocks private/internal destinations and validates every redirect.
- RAG source content is treated as untrusted data in the model prompt.
- The API joins vector hits with DynamoDB status before including passages in a response.
- IAM roles separate API, ingestion, and CloudFormation site-deployment duties.

### Security decisions to review before production

- The deployment does not create a VPC, VPC endpoints, AWS WAF, a custom domain, or organization-specific perimeter controls.
- API Gateway, Cognito Hosted UI, and CloudFront are public endpoints protected by their configured authentication and access policies.
- `http://localhost:5173` remains in production CORS and Cognito callback/logout lists to support development.
- Bedrock permissions include broad foundation-model ARN patterns to support global or cross-Region inference routing. Review them against organizational least-privilege requirements.
- SSE-S3 is used rather than customer-managed KMS keys.
- The documents bucket is not versioned.
- Uploaded source content and AI prompts may contain institutional data. Apply the institution's data classification, retention, model-use, and regional-residency policies.
- Add rate limiting, WAF rules, custom domains, centralized audit controls, and alarms according to the intended exposure and compliance requirements.

## Scaling and operational limits

| Area | Current behavior or limit |
|---|---|
| Upload size | Configurable; default 50 MiB. |
| Presigned upload validity | 15 minutes. |
| Presigned download validity | 5 minutes. |
| Links per API request | 1–20. |
| URL response size | Maximum 25 MiB. |
| URL redirects | Maximum 5. |
| URL fetch timeout | 30 seconds overall. |
| Chunks per document | Maximum 4,000 indexed chunks. |
| Approximate chunk size | About 1,200 characters with about 200 characters of overlap. |
| Embedding concurrency inside one ingestion | Up to 8 calls. |
| Vector write batch | 200 vectors. |
| Ingestion Lambda | 2,048 MB, 10-minute timeout. |
| Ingestion event batch | 1 SQS message. |
| Ingestion concurrency | Default 5. |
| SQS retries | 3 receives before DLQ. |
| DynamoDB import | Up to 20,000 items by default. |
| Spreadsheet/CSV rows | Up to 20,000 data rows per sheet/input area, subject to parser behavior. |
| RAG candidates | 16 vector candidates. |
| RAG relevance threshold | Cosine similarity of at least 0.2. |
| RAG passages sent to model | Top 8 ready-document passages. |
| Question length | Maximum 2,000 characters. |
| Conversation history | Up to 6 valid alternating turns; each capped at 4,000 characters. |
| Summary source input | First 60,000 normalized characters. |
| API throttle | 20 requests/second; burst 50. |
| Library implementation | Loads the document catalog from the GSI and filters/paginates in Lambda; intended for institute-scale collections rather than unbounded catalogs. |

Monitor Bedrock quotas, Lambda concurrency, SQS age, DLQ depth, DynamoDB usage, API throttling, and CloudFront behavior during large imports.

## Removing a deployment

### CDK

From `infra/`:

```bash
npm run destroy
```

### CloudFormation

```bash
aws cloudformation delete-stack \
  --stack-name EduKnowledgeBase \
  --region us-east-1

aws cloudformation wait stack-delete-complete \
  --stack-name EduKnowledgeBase \
  --region us-east-1
```

### Retained resources

Deletion intentionally retains content-bearing resources:

- Documents S3 bucket
- DynamoDB documents table
- S3 vector bucket
- S3 vector index
- Cognito user pool

The artifact bucket and uploaded artifact prefixes are also outside the application stack and are not deleted automatically.

Retained resources continue to incur charges and are not automatically adopted by a future stack. Back up required data, confirm ownership, and remove them manually only when they are no longer needed. S3 buckets and vector buckets must be empty before deletion.

The site bucket and deployment-managed Lambda log groups are configured for deletion with the stack. The CloudFormation site-deployer empties the site bucket during stack deletion.

## Important implementation notes

- **Two deployment definitions:** `infra/lib/kb-stack.ts` and `cloudformation/edu-kb.yaml` implement the same architecture separately. Keep both synchronized.
- **Frontend build dependency:** CDK synthesis requires `frontend/dist/index.html`. `npm run deploy` in `infra/` builds it automatically; `npm run synth` does not.
- **No default user:** defaults disable self-sign-up and leave the admin email empty. Supply an admin email or create users manually.
- **Embedding/index compatibility:** the vector index is fixed to 1,024 dimensions and cosine distance. Changing the embedding model may require creating and repopulating a compatible index.
- **Summary behavior:** eager summaries improve the first-use experience but add Bedrock calls during ingestion. Set `summarizeOnIngest`/`SummarizeOnIngest` to `false` for lazy, user-triggered summaries.
- **DynamoDB imports are snapshots:** imports and **Sync now** perform full one-time scans; they are not streams or incremental replication.
- **Retained data complicates clean recreation:** deleting and recreating the stack does not automatically reconnect retained resources to the new stack.
- **CloudFront SPA fallback:** all site-origin 403/404 responses return `index.html`, which supports client routing but can make missing static assets appear as HTML responses.
- **Artifact bucket hardening:** `package.sh` adds an S3 public-access block only when it creates the bucket. Secure and monitor pre-existing artifact buckets separately.
- **Model and service availability:** verify regional availability and quotas before deployment, especially for S3 Vectors, the selected Bedrock models, and Node.js 24 Lambda.
