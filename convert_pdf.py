#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import sys, os, subprocess, tempfile
from pathlib import Path
import fitz
import pymupdf4llm

file_path = Path(sys.argv[1])
out_dir = Path("/data/Research")
out_dir.mkdir(parents=True, exist_ok=True)

out_file = out_dir / f"{file_path.stem}.md"
failed_dir = Path("/data/Inbox_Failed")
failed_dir.mkdir(parents=True, exist_ok=True)

try:
    doc = fitz.open(str(file_path))
    num_pages = len(doc)
    text_len = sum(len(page.get_text()) for page in doc)
    doc.close()
    
    avg_chars = text_len / num_pages if num_pages > 0 else 0
    
    if avg_chars > 100:
        md_text = pymupdf4llm.to_markdown(str(file_path))
        out_file.write_text(md_text, encoding="utf-8")
        print(f"Digital PDF ({int(avg_chars)} chars/page). Converted via pymupdf4llm.")
        sys.exit(0)
    else:
        print(f"Scanned PDF ({int(avg_chars)} chars/page). Falling back to ocrmypdf...")
        
        with tempfile.TemporaryDirectory() as tmp_dir:
            ocr_output = Path(tmp_dir) / file_path.name
            ocr_tmp = Path(tmp_dir) / "ocr_tmp"
            ocr_tmp.mkdir(exist_ok=True)
            
            env = os.environ.copy()
            env["PYTHONIOENCODING"] = "utf-8"
            
            cmd = [
                "ocrmypdf",
                "--skip-text",
                "-l", "eng+rus+fra+deu+chi_sim+jpn",
                "-j", "1",
                "--output-type", "pdf",
                str(file_path),
                str(ocr_output)
            ]
            
            result = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=600)
            if result.returncode != 0:
                print(f"ocrmypdf failed (exit {result.returncode}):", file=sys.stderr)
                print(result.stderr[-1500:] if len(result.stderr) > 1500 else result.stderr, file=sys.stderr)
                sys.exit(1)
            
            if not ocr_output.exists():
                print("ocrmypdf did not produce output file", file=sys.stderr)
                sys.exit(1)
            
            md_text = pymupdf4llm.to_markdown(str(ocr_output))
            out_file.write_text(md_text, encoding="utf-8")
            print("ocrmypdf + pymupdf4llm completed successfully.")
            sys.exit(0)

except subprocess.TimeoutExpired:
    print("Timeout: ocrmypdf took more than 10 minutes", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"Fatal error: {e}", file=sys.stderr)
    sys.exit(1)
