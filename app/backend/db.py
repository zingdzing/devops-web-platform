import pymysql
from pymysql.cursors import DictCursor


class Database:
    def __init__(self, host, port, name, user, password):
        self.host = host
        self.port = port
        self.name = name
        self.user = user
        self.password = password

    @classmethod
    def from_config(cls, config):
        return cls(
            host=config["DB_HOST"],
            port=config["DB_PORT"],
            name=config["DB_NAME"],
            user=config["DB_USER"],
            password=config["DB_PASSWORD"],
        )

    def _connect(self):
        return pymysql.connect(
            host=self.host,
            port=self.port,
            user=self.user,
            password=self.password,
            database=self.name,
            cursorclass=DictCursor,
            connect_timeout=3,
            autocommit=False,
        )

    def check_connection(self):
        try:
            with self._connect() as connection:
                with connection.cursor() as cursor:
                    cursor.execute("SELECT 1")
                    cursor.fetchone()
            return True
        except pymysql.MySQLError:
            return False
