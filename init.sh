#!/usr/bin/env bash

set -e

EXPORT_PATH=/opt/export
echo "localhost:5432:$POSTGRES_DB:$POSTGRES_USER:$POSTGRES_PASSWORD" >> $HOME/.pgpass \
&& chmod 0600 $HOME/.pgpass

PGPASSFILE=$HOME/.pgpass

# Remote database connnection params
PGHOST_REMOTE=${PGHOST_REMOTE:-localhost}
PGPORT_REMOTE=${PGPORT_REMOTE:-5432}
PGUSER_REMOTE=${PGUSER_REMOTE:-postgres}
PGDATABASE_REMOTE=${PGDATABASE_REMOTE:-postgres}
PGPASSWORD_REMOTE=${PGPASSWORD_REMOTE:-postgres}

#Set up the export functionnalities
psql -h localhost \
     -U $POSTGRES_USER \
     -d $POSTGRES_DB \
    -v rhost=\'${PGHOST_REMOTE}\' \
    -v rdb=\'${PGDATABASE_REMOTE}\' \
    -v rport=\'${PGPORT_REMOTE}\' \
    -v ruser=\'${PGUSER_REMOTE}\' \
    -v rpwd=\'${PGPASSWORD_REMOTE}\' \
    -f /opt/init.sql

#Don't keep remote password
PG_REMOTE_PASSWORD=''

#Rotate the export logs
echo -e "$EXPORT_PATH/export.log {
    rotate 2
    size 100M
    compress
    missingok
    notifempty
}" > /opt/export_log_rotate.conf \
&& ln -s /opt/export_log_rotate.conf /etc/logrotate.d/export_log_rotate.conf

#Create the export job
CRON_SCHEDULE=${CRON_SCHEDULE:-0 0 * * *} \
&& echo -e "$CRON_SCHEDULE /opt/export.sh $EXPORT_PATH | tee $EXPORT_PATH/export.log > $EXPORT_PATH/last_report.txt 2>&1" \
| crontab - \
&& cron \
&& crontab -l

touch $EXPORT_PATH/export.log \
&& tail -F $EXPORT_PATH/export.log #Follow + retry to keep displaying the file even after rotate occured