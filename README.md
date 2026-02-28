# 🛒 Cartly

Cartly is an open-source iOS app that demonstrates how to build a real AI product on Mnexium.
It is not a toy chatbot. It is a working reference for chat, history, OCR ingestion, and schema-backed records in one app.

## 🎯 Purpose

Cartly exists to show developers what Mnexium enables when you combine:

- conversational AI
- persistent memory context
- structured application data
- deterministic records writes
- real multi-thread chat history

## 🚀 Why Mnexium

Mnexium gives you a single runtime model for AI apps:

- One `mnx` context object to control behavior (`history`, `learn`, `recall`, `records`, and more).
- Stable identity model with `subject_id` and `chat_id` for durable conversations.
- Native Records layer for typed entities, schema validation, and CRUD/query workflows.
- Chat + data workflows in the same request pipeline (for example, receipt extraction -> records sync).
- Production-friendly controls like retries, request tracing, and explicit sync semantics.

In short: Mnexium helps you ship AI apps that are useful after the first prompt, not just impressive in a demo.

## 🧰 Mnexium Tooling In This Project

Cartly was built as a Mnexium-first app. The implementation directly uses Mnexium APIs and request patterns rather than treating Mnexium as a black box.

### 🤖 Skill Used: `mnexium-app-builder`

This project was also developed using the `mnexium-app-builder` Codex skill to keep implementation aligned with Mnexium best practices for:

- stable `subject_id` / `chat_id` usage
- chat + history endpoint mapping
- records schema and CRUD correctness
- `mnx.records.sync` persistence behavior
- retry/error handling and integration hardening

You can learn more about Mnexium skills and tooling in the official docs:

- [Mnexium Docs](https://mnexium.com/docs)

How Mnexium is used in this codebase:

- Mnexium chat runtime via `POST /api/v1/chat/completions`
- Mnexium chat history toolchain via:
  - `GET /api/v1/chat/history/list`
  - `GET /api/v1/chat/history/read`
- Mnexium Records schema management via `POST /api/v1/records/schemas`
- Mnexium Records CRUD/query for `receipts` and `receipt_items`
- Mnexium records sync orchestration using `mnx.records.sync=true` for OCR persistence

Where to see the integration:

- `Cartly/Mnexium/MnexiumClient+Chat.swift`
- `Cartly/Mnexium/MnexiumClient+Records.swift`
- `Cartly/Mnexium/MnexiumClient+Transport.swift`
- `Cartly/Mnexium/MnexiumClient+Parsing.swift`

## 🧠 What Cartly Demonstrates

### 💬 Streaming Chat with Memory Context

Cartly calls `POST /api/v1/chat/completions` with an `mnx` object including:

- `subject_id`
- `chat_id`
- `history=true`
- `learn=true`
- `recall=true`
- records context for `receipts` and `receipt_items`

### 🗂 Chat History Sidebar

Cartly loads real thread history with:

- `GET /api/v1/chat/history/list`
- `GET /api/v1/chat/history/read`

Users can switch across previous chats, not just keep one ephemeral session.

### 📸 Receipt OCR -> Structured Records

The receipt capture flow:

1. Capture photo from camera.
2. Compress and send image for OCR parsing.
3. Send parsed JSON in a non-stream persistence request.
4. Sync to Mnexium Records using `mnx.records.sync=true`.

This pattern is a strong template for AI extraction workflows in production apps.

### 🧾 Records CRUD

The Data tab demonstrates:

- list receipts
- create manual receipts
- delete receipts
- query receipt items by `receipt_id`
- create and delete receipt items

## 🧱 Mnexium Records Schema

This repo includes a reusable schema definition file:

- [`mnexium-records-schema.json`](mnexium-records-schema.json)

Defined tables:

- `receipts`
- `receipt_items` (`receipt_id` is `ref:receipts`)

## 🔌 Mnexium Endpoints Used

- `POST /api/v1/chat/completions`
- `GET /api/v1/chat/history/list`
- `GET /api/v1/chat/history/read`
- `POST /api/v1/records/schemas`
- `GET /api/v1/records/receipts`
- `POST /api/v1/records/receipts`
- `DELETE /api/v1/records/receipts/:id`
- `POST /api/v1/records/receipt_items`
- `POST /api/v1/records/receipt_items/query`
- `DELETE /api/v1/records/receipt_items/:id`

## 🗃 Project Structure

- `Cartly/ContentView.swift`: Data, Chat, and More tabs
- `Cartly/ReceiptCaptureViewModel.swift`: app orchestration
- `Cartly/ReceiptParsingSupport.swift`: identity and local key settings
- `Cartly/Mnexium/`: Mnexium client modules
- `mnexium-records-schema.json`: canonical records schema for this app

## 🛠 Run Locally

### Requirements

- Xcode
- iOS Simulator or iOS device supported by the project

### Setup

1. Open `Cartly.xcodeproj`.
2. Build and run the `Cartly` scheme.
3. Open **More** tab.
4. Enter Mnexium API Key and OpenAI API Key (optional).
5. Save.
6. Leave Mnexium key empty to fall back to the app-provided key path.

## 🔐 Security Note

For demo speed, user-entered keys are stored locally in `UserDefaults`.
For production, use Keychain for device secrets and keep provider keys server-side.

## 🌟 What To Build Next

Cartly covers only part of Mnexium. You can extend this app with:

- profile-aware personalization
- claim/truth graph flows
- stateful agent workflows
- memory policy tuning
- semantic search over business records

If you are evaluating Mnexium, this repo is designed to be cloned, modified, and used as a launchpad for your own AI product.
