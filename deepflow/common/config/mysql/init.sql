    ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY 'deepflow';
    CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'deepflow';
    GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION;