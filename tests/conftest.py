"""Make the Lambda source importable without packaging it."""
import os
import sys

LAMBDA_DIR = os.path.join(
    os.path.dirname(os.path.dirname(__file__)),
    "modules", "cleanup", "lambda",
)
sys.path.insert(0, LAMBDA_DIR)
