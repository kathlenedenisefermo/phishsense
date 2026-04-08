from fastapi import FastAPI
from pydantic import BaseModel
import onnxruntime as ort
import numpy as np
import json
import os
from tokenizers import Tokenizer
from huggingface_hub import hf_hub_download

app = FastAPI()

# Download model files from Hugging Face
REPO_ID = "joaquinkriztel/phishsense-model"
MODEL_PATH = hf_hub_download(repo_id=REPO_ID, filename="phishsense_model.onnx")
TOKENIZER_PATH = hf_hub_download(repo_id=REPO_ID, filename="tokenizer.json")
LABEL_MAP_PATH = hf_hub_download(repo_id=REPO_ID, filename="label_map.json")

session = ort.InferenceSession(MODEL_PATH)
tokenizer = Tokenizer.from_file(TOKENIZER_PATH)
tokenizer.enable_truncation(max_length=128)
tokenizer.enable_padding(length=128, pad_id=1)

with open(LABEL_MAP_PATH) as f:
    label_map = json.load(f)

class MessageRequest(BaseModel):
    message: str

@app.post("/predict")
def predict(req: MessageRequest):
    encoding = tokenizer.encode(req.message)
    input_ids = np.array([encoding.ids], dtype=np.int64)
    attention_mask = np.array([encoding.attention_mask], dtype=np.int64)

    inputs = {
        "input_ids": input_ids,
        "attention_mask": attention_mask
    }

    outputs = session.run(None, inputs)
    logits = outputs[0][0]
    predicted = int(np.argmax(logits))
    confidence = float(np.exp(np.max(logits)) / np.sum(np.exp(logits)))
    label = label_map[str(predicted)]

    return {
        "label": label,
        "confidence": round(confidence * 100, 2),
        "predicted_class": predicted
    }

@app.get("/health")
def health():
    return {"status": "ok"}
