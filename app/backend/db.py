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

    @staticmethod
    def _select_item(cursor, item_id):
        cursor.execute(
            """
            SELECT id, title, description, status, created_at, updated_at
            FROM ops_tasks
            WHERE id = %s
            """,
            (item_id,),
        )
        return cursor.fetchone()

    def check_connection(self):
        try:
            with self._connect() as connection:
                with connection.cursor() as cursor:
                    cursor.execute("SELECT 1")
                    cursor.fetchone()
            return True
        except pymysql.MySQLError:
            return False

    def list_items(self):
        with self._connect() as connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    """
                    SELECT id, title, description, status, created_at, updated_at
                    FROM ops_tasks
                    ORDER BY created_at DESC, id DESC
                    """
                )
                return cursor.fetchall()

    def create_item(self, title, description, status):
        with self._connect() as connection:
            try:
                with connection.cursor() as cursor:
                    cursor.execute(
                        """
                        INSERT INTO ops_tasks (title, description, status)
                        VALUES (%s, %s, %s)
                        """,
                        (title, description, status),
                    )
                    item_id = cursor.lastrowid
                    item = self._select_item(cursor, item_id)
                connection.commit()
                return item
            except pymysql.MySQLError:
                connection.rollback()
                raise

    def update_item(self, item_id, title, description, status):
        with self._connect() as connection:
            try:
                with connection.cursor() as cursor:
                    cursor.execute(
                        """
                        UPDATE ops_tasks
                        SET title = %s, description = %s, status = %s
                        WHERE id = %s
                        """,
                        (title, description, status, item_id),
                    )
                    if cursor.rowcount == 0:
                        connection.rollback()
                        return None
                    item = self._select_item(cursor, item_id)
                connection.commit()
                return item
            except pymysql.MySQLError:
                connection.rollback()
                raise

    def delete_item(self, item_id):
        with self._connect() as connection:
            try:
                with connection.cursor() as cursor:
                    cursor.execute("DELETE FROM ops_tasks WHERE id = %s", (item_id,))
                    deleted = cursor.rowcount > 0
                connection.commit()
                return deleted
            except pymysql.MySQLError:
                connection.rollback()
                raise
