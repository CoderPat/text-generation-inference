import os
import json
import argparse
from transformers import AutoTokenizer

def dump_fast_tokenizer(tokenizer_name, output_path):
    tokenizer = AutoTokenizer.from_pretrained(tokenizer_name)
    tokenizer.save_pretrained(output_path)

def main():
    parser = argparse.ArgumentParser(description="Dump fast tokenizer json file")
    parser.add_argument("--tokenizer-name", required=True, help="Name of the Hugging Face tokenizer")
    parser.add_argument("--output", required=True, help="Output path for the fast tokenizer json file")
    args = parser.parse_args()

    dump_fast_tokenizer(args.tokenizer_name, args.output)

if __name__ == "__main__":
    main()