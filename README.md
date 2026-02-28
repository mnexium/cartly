# Cartly

Cartly is an open-source iOS demo app that shows how to build a production-style AI experience on top of Mnexium.

The goal is simple: give developers a clear, working example of how far Mnexium can go in one app, including chat, history, OCR ingestion, and schema-backed Records.

## Why This App Exists

Cartly is intentionally built as a practical reference implementation for:

- Mnexium chat with streaming responses
- Mnexium chat history list/read flows
- OCR-style receipt ingestion with image input
- Mnexium Records schema creation and CRUD
- subject/chat identity management
- records sync via `mnx.records.sync=true`

## What It Demonstrates

### 1) AI Chat + Memory Context

The chat tab sends prompts to `/api/v1/chat/completions` with an `mnx` object that includes:

- `subject_id`
- `chat_id`
- `history`, `learn`, `recall`
- Records context (`tables: ["receipts", "receipt_items"]`)

Streaming is enabled for chat responses.

### 2) Chat History Sidebar

Chat history is loaded using:

- `GET /api/v1/chat/history/list`
- `GET /api/v1/chat/history/read`

This powers a multi-chat sidebar where users can switch threads and load prior messages.

### 3) Receipt Capture -> OCR -> Records Sync

Camera capture flow:

1. User captures a receipt photo.
2. Image is compressed and sent to Mnexium chat OCR prompt.
3. Parsed JSON is sent in a second non-stream request with:
   - `mnx.records.sync=true`
   - `mnx.records.learn="force"`
   - `tables=["receipts","receipt_items"]`
4. Mnexium writes structured rows to Records.

### 4) Records CRUD UI

The Data tab demonstrates:

- List receipt records
- Swipe delete receipts
- Query receipt items by `receipt_id`
- Add manual receipt records
- Add/delete manual receipt item records

## Mnexium Records Schema

This repo includes a reusable schema file:

- [`mnexium-records-schema.json`](/Users/mariusndini/Documents/GitHub/Cartly/mnexium-records-schema.json)

It defines:

- `receipts`
- `receipt_items` (with `receipt_id` as `ref:receipts`)

## Project Structure

- `/Cartly/ContentView.swift` UI (Data / Chat / More tabs)
- `/Cartly/ReceiptCaptureViewModel.swift` app orchestration and error handling
- `/Cartly/Mnexium/` Mnexium client modules
  - `MnexiumClient+Chat.swift`
  - `MnexiumClient+Records.swift`
  - `MnexiumClient+Transport.swift`
  - `MnexiumClient+Parsing.swift`
  - `MnexiumPayloads.swift`
  - `MnexiumConfiguration.swift`
- `/Cartly/ReceiptParsingSupport.swift` identity and local key storage

## Running The App

### Requirements

- Xcode (current toolchain)
- iOS Simulator/device supported by the project

### Setup

1. Open `Cartly.xcodeproj` in Xcode.
2. Build and run the `Cartly` scheme.
3. Configure API keys:
   - Option A: use app-provided key flow (default)
   - Option B: open **More** tab and set:
     - Mnexium API Key
     - OpenAI API Key

If Mnexium API key is blank in More tab, Cartly falls back to the app-provided key path.

## Security Note

For demo ergonomics, user-entered keys in the More tab are currently stored locally in `UserDefaults`.
For hardened production apps, move secrets to Keychain and keep provider keys server-side whenever possible.

## Intended Audience

This repo is designed for developers evaluating Mnexium as an application runtime for AI products.
It is meant to be read, modified, and reused as a base for your own app.
