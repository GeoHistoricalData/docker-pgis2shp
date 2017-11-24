FROM mdillon/postgis:9.6

MAINTAINER Bertrand Dumenieu  <bertrand.dumenieu@ehess.fr>

#Install backup utilities
RUN apt-get -y install cron \ 
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

#Export script  : init.sh/.sql prepare the export database, export.sh does the actual export.
COPY init.sh init.sql export.sh /opt/

RUN chmod +x /opt/init.sh \
    && chmod +x /opt/export.sh \
    && mkdir -p /opt/export

#Run export scripts as root
RUN echo "exec gosu root bash -c '/opt/init.sh'" > /docker-entrypoint-initdb.d/initialize_export.sh

#Allow gosu to be executed as any user
RUN chmod +s /usr/local/bin/gosu

CMD ["postgres"]
