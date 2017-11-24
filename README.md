# PostGIS to Shapefile exporter 

Docker image to export PostGIS tables from a remote database to shapefiles.

This image is currently used to automate daily exports of geographical databases and their publication on the download page of geohistoricaldata.org.


The scripts `init.sql` and `export.sh` are specific to the GeoHistoricalData database but can be modified or replaced to adapt this image to your own project.

Built upon [mdillon/postgis](https://hub.docker.com/r/mdillon/postgis/) with PostgreSQL 9.6 and PostGIS 2.3


## 1. Configuration

Configuring the PostGIS exporter is solely based on environment variables.

#### Local database connection

- `POSTGRES_USER`: The user of the local postgresql instance. Default=*postgres*.
- `POSTGRES_PASSWORD`: Password of the local postgresql user. Default=*none*.
- `POSTGRES_DB`: Local database to use. Default=`$POSTGRES_USER`.

#### Remote database connection

- `PGHOST_REMOTE`: Name of remote host to export from. Default=*localhost*.
- `PGPORT_REMOTE`: Port number to connect to at the remote server. Default=*5432*.
- `PGDATABASE_REMOTE`: Remote database to use. Default=*postgres*.
- `PGUSER_REMOTE`: User name to connect as at the remote server. Default=*postgres*.
- `PGPASSWORD_REMOTE`: The password for `PGUSER_REMOTE`. Default=*postgres*.

#### Scheduling exports

- `CRON_SCHEDULE`: Cron format for running exports. Default is *'0 0 \* \* \* '*.

## 2. Usage

1. Build

```docker build -t pgis2shp:1.0 ```

2. Run

Execute export.sh to export geodata from foo.bar every monday at midnight :

```docker run -d -e "PGHOST_REMOTE=foo.bar" -e "PGPORT_REMOTE=5432" -e "PGDATABASE_REMOTE=my-remote-db" -e "PGUSER_REMOTE=someuser" -e "PGPASSWORD_REMOTE=somepassword" -e CRON_SCHEDULE='0 0 * * 1' pgis2shp:1.0```

## 3. Security issues with postgreSQL passwords


The image has been designed to avoid storing postgreSQL password as much as possible. Yet passwords for local and remote connections are exposed in three places:

- Remote DB password is exposed by the ```FOREIGN SERVER``` if ```GRANT USAGE on FOREIGN SERVER ``` is applied.
- Local DB password is exposed in `/root/.pgpass`
- Local DB password is stored in the environment variable `POSTGRES_PASSWORD`

If the foreign server contains sensitive data, you should create special roles with read-only permissions to be used by the exporter.

**Never connect to the remote database with superuser permissions!**

