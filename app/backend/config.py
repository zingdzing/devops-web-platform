import os


def load_config():
    return {
        "DB_HOST": os.getenv("DB_HOST", "127.0.0.1"),
        "DB_PORT": int(os.getenv("DB_PORT", "3306")),
        "DB_NAME": os.getenv("DB_NAME", "ops_tasks"),
        "DB_USER": os.getenv("DB_USER", "ops_app"),
        "DB_PASSWORD": os.getenv("DB_PASSWORD", ""),
        "FLASK_HOST": os.getenv("FLASK_HOST", "127.0.0.1"),
        "FLASK_PORT": int(os.getenv("FLASK_PORT", "5000")),
    }
