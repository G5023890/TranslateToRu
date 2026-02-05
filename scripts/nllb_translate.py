#!/usr/bin/env python3
import argparse
import os
import re
import sys


def find_model_dir(models_dir: str) -> str:
    if os.path.isfile(os.path.join(models_dir, "model.bin")):
        return models_dir
    if not os.path.isdir(models_dir):
        raise FileNotFoundError(f"Models dir not found: {models_dir}")
    for name in sorted(os.listdir(models_dir)):
        candidate = os.path.join(models_dir, name)
        if os.path.isfile(os.path.join(candidate, "model.bin")):
            return candidate
    raise FileNotFoundError("No CTranslate2 model found (missing model.bin)")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--models-dir", required=True)
    parser.add_argument("--src", required=True)
    parser.add_argument("--dst", required=True)
    parser.add_argument("--tokenizer-dir", default=None)
    parser.add_argument("--beam-size", type=int, default=4)
    parser.add_argument("--max-chars", type=int, default=2000)
    args = parser.parse_args()

    lang_map = {
        "en": "eng_Latn",
        "ru": "rus_Cyrl",
        "he": "heb_Hebr",
    }
    src_lang = lang_map.get(args.src, args.src)
    dst_lang = lang_map.get(args.dst, args.dst)

    try:
        import ctranslate2
        from transformers import AutoTokenizer
    except Exception as exc:
        print(f"Missing Python deps: {exc}", file=sys.stderr)
        return 1

    try:
        model_dir = find_model_dir(args.models_dir)
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 1

    tokenizer_dir = args.tokenizer_dir or model_dir
    try:
        tokenizer = AutoTokenizer.from_pretrained(tokenizer_dir, src_lang=src_lang, use_fast=False)
    except Exception as exc:
        print(f"Tokenizer load failed: {exc}", file=sys.stderr)
        return 1

    translator = ctranslate2.Translator(model_dir, device="cpu", compute_type="int8")

    text = sys.stdin.read()
    if not text.strip():
        return 0

    lang_code_to_id = getattr(tokenizer, "lang_code_to_id", None) or {}
    target_id = lang_code_to_id.get(dst_lang)
    if target_id is None:
        # Fallback: some tokenizer builds expose the language code as a token
        target_id = tokenizer.convert_tokens_to_ids(dst_lang)
    if target_id is None or target_id == getattr(tokenizer, "unk_token_id", None):
        print(f"Tokenizer missing language code token for {dst_lang}", file=sys.stderr)
        return 1

    def split_sentences(paragraph: str) -> list[str]:
        parts = re.split(r"(?<=[\\.!?])\\s+", paragraph.strip())
        return [p for p in parts if p]

    def chunk_text(full_text: str, max_chars: int) -> list[str]:
        paragraphs = [p for p in full_text.split("\\n\\n") if p.strip()]
        chunks: list[str] = []
        for para in paragraphs:
            if len(para) <= max_chars:
                chunks.append(para.strip())
                continue
            current = ""
            for sentence in split_sentences(para):
                if not current:
                    current = sentence
                elif len(current) + 1 + len(sentence) <= max_chars:
                    current = current + " " + sentence
                else:
                    chunks.append(current)
                    current = sentence
            if current:
                chunks.append(current)
        return chunks

    def translate_chunk(chunk: str) -> str:
        tokens = tokenizer.convert_ids_to_tokens(tokenizer.encode(chunk))
        target_token = tokenizer.convert_ids_to_tokens([target_id])[0]
        results = translator.translate_batch(
            [tokens],
            target_prefix=[[target_token]],
            beam_size=args.beam_size,
            max_decoding_length=512,
        )
        hypothesis = results[0].hypotheses[0]
        if hypothesis and hypothesis[0] == target_token:
            hypothesis = hypothesis[1:]
        output_ids = tokenizer.convert_tokens_to_ids(hypothesis)
        return tokenizer.decode(output_ids, skip_special_tokens=True).strip()

    chunks = chunk_text(text, args.max_chars)
    outputs = [translate_chunk(chunk) for chunk in chunks]
    sys.stdout.write("\\n\\n".join(outputs).strip())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
