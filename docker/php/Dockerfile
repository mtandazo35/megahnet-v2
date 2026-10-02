# Imagen de la aplicacion para el entorno LOCAL de desarrollo.
#
# Reproduce lo que instala install.sh en Debian: PHP 8.4 con las mismas
# extensiones, Apache con mod_rewrite y el proveedor "legacy" de OpenSSL que
# necesitan los certificados de firma del SRI.
#
# Nota: en produccion PHP NO corre en contenedor (va con Apache sobre Debian).
# Esto sirve para programar y probar la aplicacion, no para validar la maquina:
# permisos, temporizadores y arranque de sistema no se comprueban aqui.
FROM php:8.4-apache

# Paquetes necesarios para compilar las extensiones y para el dia a dia.
# default-mysql-client hace falta para los respaldos y para las migraciones.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libpng-dev libjpeg62-turbo-dev libfreetype6-dev \
        libicu-dev libxml2-dev libzip-dev libonig-dev \
        libmagickwand-dev \
        default-mysql-client \
        unzip git \
    && rm -rf /var/lib/apt/lists/*

# Las mismas extensiones que pone install.sh en el servidor.
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        pdo_mysql mysqli gd intl zip soap bcmath mbstring xml \
    && pecl install imagick \
    && docker-php-ext-enable imagick

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# OpenSSL: los certificados .p12 del SRI usan algoritmos que OpenSSL 3 dejo en
# el proveedor "legacy". En el servidor esto obliga a tocar la configuracion
# GLOBAL del sistema, que es uno de los problemas senalados en la auditoria.
# Aqui queda encerrado en el contenedor, que es justo como deberia estar.
RUN printf '%s\n' \
    'openssl_conf = openssl_init' \
    '' \
    '[openssl_init]' \
    'providers = provider_sect' \
    '' \
    '[provider_sect]' \
    'default = default_sect' \
    'legacy = legacy_sect' \
    '' \
    '[default_sect]' \
    'activate = 1' \
    '' \
    '[legacy_sect]' \
    'activate = 1' \
    > /usr/local/ssl/openssl-sri.cnf 2>/dev/null \
    || { mkdir -p /usr/local/ssl && printf '%s\n' \
        'openssl_conf = openssl_init' '' '[openssl_init]' 'providers = provider_sect' '' \
        '[provider_sect]' 'default = default_sect' 'legacy = legacy_sect' '' \
        '[default_sect]' 'activate = 1' '' '[legacy_sect]' 'activate = 1' \
        > /usr/local/ssl/openssl-sri.cnf; }
ENV OPENSSL_CONF=/usr/local/ssl/openssl-sri.cnf

# El sistema usa URL limpias y .htaccess, igual que el vhost de produccion.
RUN a2enmod rewrite headers
RUN printf '%s\n' \
    '<Directory /var/www/html>' \
    '    Options -Indexes +FollowSymLinks' \
    '    AllowOverride All' \
    '    Require all granted' \
    '</Directory>' \
    > /etc/apache2/conf-available/megahnet.conf \
    && a2enconf megahnet

# Errores a la vista: esto es un entorno de desarrollo, no produccion.
RUN printf '%s\n' \
    'display_errors = On' \
    'error_reporting = E_ALL' \
    'upload_max_filesize = 64M' \
    'post_max_size = 64M' \
    'max_execution_time = 300' \
    'date.timezone = America/Guayaquil' \
    > /usr/local/etc/php/conf.d/megahnet-local.ini

COPY docker/php/entrada.sh /usr/local/bin/entrada.sh
RUN chmod +x /usr/local/bin/entrada.sh

ENTRYPOINT ["/usr/local/bin/entrada.sh"]
CMD ["apache2-foreground"]
