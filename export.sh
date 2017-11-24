#!/bin/bash
echo -e '----------------------------------------------------------------\n' \
'Export started on' $(date) \
'\n----------------------------------------------------------------'
export_path=$1

#pgsql2shp doesn't use .pgpass so we have to explicitely get connection infos from it.
#If no .pgpass entry is found for localhost, try to get information from the environment
#variables defined in the official postgreSQL image.
if [[ -n $(cat $HOME/.pgpass | grep localhost) ]]; then
  #Read the connection infos in the .pgpass file
  IFS=':' read -r -a cnfo <<< $(cat $HOME/.pgpass | grep localhost)
  PGHOST='localhost'
  PGPORT=${cnfo[1]}
  PGDATABASE=${cnfo[2]}
  PGUSER=${cnfo[3]}
  PGPASSWORD=${cnfo[4]}
else
  PGHOST='localhost'
  PGPORT='5432'
  PGDATABASE=$POSTGRES_DB
  PGUSER=$POSTGRES_USER
  PGPASSWORD=$POSTGRES_PASSWORD
fi

psql_local="psql -h $PGHOST -U $PGUSER -d $PGDATABASE -q -t -c "
#======================================================================
# Export of all Paris networks in the GHDB database Paris found in the
# schema 'networks'.
remote_schema=streetnets

qlistnets="SELECT * FROM dblink(
  'foreign_db'::text,
  'WITH tbllist AS 
        (SELECT table_catalog, table_schema, table_name
         FROM information_schema.tables
         WHERE table_schema = ''$remote_schema''
        )
        SELECT tbllist.table_name 
        FROM tbllist 
        JOIN public.geometry_columns AS gc 
        ON tbllist.table_catalog = gc.f_table_catalog 
        AND tbllist.table_schema = gc.f_table_schema 
        AND tbllist.table_name = gc.f_table_name 
        WHERE coord_dimension=2'::text
  ) AS remote(table_name text)"

succ=0
fail=0

#Do all the work in the volatile directory /tmp
[ -d  /tmp/networks ] || mkdir /tmp/networks
cd /tmp/networks

#Export each network to a shapefile
networks=$($psql_local "$qlistnets")
for tbl in ${networks[@]};
do
  echo 'Exporting network '$remote_schema'.'$tbl''
  [ -d ${tbl} ] || mkdir ${tbl} #One export dir per network
  cd ${tbl}
  touch .version
  
  #Check if the network has been modified since the last export by comparing the last version number of the table in the audit table (vnew) 
  #against the last version number found in .version (vold)
  #If vnew is null (i.e. the table isn't versionned): new export.
  #Else if vnew <> vold make a ne export and set vold=vnew.
  #Else if vnew == vold don't do anything.
  vnew=$($psql_local "SELECT vnum 
                      FROM dblink('foreign_db',
                                  'SELECT event_id as vnum 
                                  FROM audit.logged_actions 
                                  WHERE schema_name=''$remote_schema'' 
                                  AND table_name=''$tbl'' 
                                  ORDER BY action_tstamp_tx DESC 
                                  LIMIT 1')
                            AS t(vnum integer)"
        )
  vold=$(cat .version)
  if [ -z "$vnew" ]||[ -z "$vold" ]||[ "$vnew" != "$vold" ]; then
      echo "New version found: ${vnew:-'unversionned'} (previously ${vold:-'none'})."
      #Actually export the network
      $psql_local "SET client_min_messages TO WARNING; SELECT remote_net_cleanup('foreign_db','$remote_schema','$tbl','gid','geom',2.0);" \
      && pgsql2shp -r -f ${tbl}.shp -k -h localhost -u $PGUSER $(if [[ -n $PGPASSWORD ]]; then echo "-P $PGPASSWORD"; fi) $PGDATABASE  \
        "SELECT edge_id AS gid, streetname, note, edge_geom AS geom FROM cleaned_${remote_schema}_${tbl}.${tbl}" \
      && find . -name "*.shp" -o -name "*.dbf" -o -name "*.shx" -o -name "*.prj" -o -name "*.cpg" | tar -C . --remove-files -zcf ${tbl}.tar.gz -T - \
      && echo $vnew > .version \
  else
    echo "$vnew is already the latest version available."
  fi
  cp ${tbl}.tar.gz .. &&
  let "succ++"
  cd /tmp/networks
done

#Compress everything and send it to the export dir
touch info.txt \
&& echo 'Exported on' $(date +%Y-%m-%d-%H:%M) | tee info.txt 

tar --remove-files -zcf $export_path/networks.tar.gz *.tar.gz info.txt

#pgsql2shp -r -f ${tbl}_err.shp -k -h localhost -u $PGUSER $(if [[ -n $PGPASSWORD ]]; then echo "-P $PGPASSWORD"; fi) $PGDATABASE  "SELECT * FROM cleaned_${remote_schema}_${tbl}.cleanup_errors" \

#R
echo -e "----------------------------------------------------------------\n" \
"Export ended on" $(date) \
"\n $succ/${#networks[@]} network(s) exported successfuly" \
"\n $(tar -tzf ${export_path}/networks.tar.gz | wc -l) files exported:\n" 
tar -ztf ${export_path}/networks.tar.gz
echo '----------------------------------------------------------------'

cd $PWD