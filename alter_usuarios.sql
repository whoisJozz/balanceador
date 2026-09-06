-- Ejecutar en el nodo mysql-primary (se replicará a las réplicas)
USE ecommerce_db;

-- Añadir columna de contraseña (texto plano a propósito, es un lab vulnerable)
ALTER TABLE usuarios ADD COLUMN password VARCHAR(100) NOT NULL DEFAULT '';

-- Asignar credenciales de prueba a los usuarios ya existentes
UPDATE usuarios SET password = 'admin123'   WHERE email = 'admin@tienda.com';
UPDATE usuarios SET password = 'cliente123' WHERE email = 'cliente@correo.com';

-- (Opcional) usuario extra para tener más filas que enumerar con UNION-based SQLi
INSERT INTO usuarios (nombre, email, password) VALUES
('Soporte Tecnico', 'soporte@tienda.com', 'soporte2024');
