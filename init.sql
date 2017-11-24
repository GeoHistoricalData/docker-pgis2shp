---------------------------------
--  POSTGIS EXPORTER
---------------------------------

------------------------------------------------------
--  0.1. Install all required extensions
------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_topology;
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
CREATE EXTENSION IF NOT EXISTS dblink;

------------------------------------------------------
--  1. Remote network export functions
------------------------------------------------------
CREATE OR REPLACE FUNCTION net_cleanup_topology(
    atopology varchar,
    input_schema varchar,
    input_table varchar,
    col_pk varchar = 'id',
    col_geom varchar = 'geom',
    tolerance double precision = 1.0,
    report boolean = FALSE  
    )
  RETURNS integer[] AS
$BODY$
DECLARE
  network_layer_id integer;
  _sql text;
  netsrid integer;
  pk_type text;
  i integer = 0;
  report_inputlines integer = 0;
  report_outputlines integer = 0;
  report_nmod integer = 0;
  report_ndup integer = 0;
  report_nsplit integer = 0;
  report_nnullen integer = 0;
BEGIN
  RAISE DEBUG 'Network %: starting topological cleanup.',input_table;
  RAISE DEBUG 'Snapping tolerance set to %', tolerance;

  -- ====================================================================
  --                        Initial cleanup 

  PERFORM topology.DropTopology(atopology) 
  WHERE EXISTS (SELECT * FROM topology.topology WHERE name = atopology );
  

  -- ====================================================================
  --         Retrieve information about the network to clean

  -- Because we don't have direct access to the remote postgres_catalog, we cannot
  -- check if col_pk is the primary key of the table.
  -- Instead we simply check for duplicates and fail if the column col_pk contains any.
  _sql := 'SELECT 1
          FROM %I.%I
          GROUP BY %I
          HAVING count(%I) > 1
          LIMIT 1'; -- Fast way to check for duplicates in a column.
  EXECUTE format(_sql,input_schema,input_table,col_pk,col_pk) INTO i;
  IF i THEN
    RAISE EXCEPTION 'Key column % contains duplicates.',col_pk;
  END IF; 
  RAISE DEBUG 'Continuing with key column %', col_pk;
  
  --Keep the type of the key column for later and the SRID of the geometries of the network.
  --Because GEOMETRY_COLUMNS is not a foreign table we use the SRID of the first geometry found in the table.
  _sql := 'SELECT pg_typeof(%I), 
                  ST_SRID(%I)
          FROM %I.%I
          LIMIT 1';
  EXECUTE format(_sql,col_pk, col_geom, input_schema,input_table)
  INTO pk_type, netsrid;
  
  RAISE DEBUG 'PK type=%', pk_type;
  RAISE DEBUG 'Using SRID=%', netsrid;

  -- ====================================================================
  --         Prepare the export schema

  -- Create a new topology schema (with SRID netsrid)
  RAISE DEBUG 'Buidling the topology table';  
  PERFORM topology.CreateTopology(atopology, netsrid);
  _sql := 'CREATE TABLE %I.network AS 
            SELECT %I as id,
                   %I as geom
            FROM %I.%I';
  EXECUTE format(_sql, atopology, col_pk, col_geom, input_schema,input_table);

  -- Add spatial indexing to the table
  _sql := 'CREATE INDEX network_index 
                  ON %I.network 
                  USING gist(%I)';
  EXECUTE format(_sql, atopology, col_geom);

  -- Add a topogeometry column to the table
  EXECUTE format('SELECT topology.AddTopoGeometryColumn(''%I'',''%I'', ''network'', ''topo_geom'', ''LINESTRING'')',atopology, atopology) 
  INTO network_layer_id;

  _sql := 'ALTER TABLE %I.network 
           ADD COLUMN n_edges INTEGER';
  EXECUTE format(_sql, atopology);

  -- Prepare the output tables
  -- Store the cleaned edges
  _sql := 'CREATE TABLE %I.cleaned_network
          (
            edge_id INTEGER NOT NULL,
            start_node integer NOT NULL,
            end_node integer NOT NULL,
            edge_geom geometry NOT  NULL,
            net_id %s NOT NULL,
            CONSTRAINT network_edges_pk PRIMARY KEY (edge_id)
          )';
  EXECUTE format(_sql, atopology, pk_type);
  
  _sql := 'CREATE INDEX cleaned_network_index 
                  ON %I.cleaned_network 
                  USING gist(edge_geom)';
  EXECUTE format(_sql, atopology);

  -- Store all edges that are erroneous or that have been modified during the process.
  _sql := 'CREATE TABLE %I.cleanup_errors
          (
            errid SERIAL,
            net_id %s NOT NULL,
            net_geom geometry NOT NULL,
            edges_id integer[] NOT NULL,
            edges_geoms geometry NOT NULL,
            err TEXT NOT NULL
          )';
  EXECUTE format(_sql, atopology, pk_type);
  
  -- ====================================================================
  --          Actually do the cleanup and track errors

  -- Create topogeometries for the network using a snapping tolerance.
  RAISE DEBUG 'Buidling topogeometries.';
  _sql := 'UPDATE %I.network 
           SET topo_geom = topology.toTopoGeom(geom, ''%I'', $1, $2)';
  EXECUTE format(_sql,atopology, atopology)
  USING network_layer_id, tolerance;

  -- Temporary result table
  _sql := 'CREATE TEMPORARY TABLE results
          ON COMMIT DROP
          AS 
          (
            SELECT row_number() OVER () as rnum,
                   edge_id, 
                   net_id,
                   edata.geom as edge_geom,
                   net_geom,
                   ST_LENGTH(edata.geom) AS edgelen
            FROM (
              SELECT id AS  net_id,
                     geom as net_geom,
                     topo_geom,
                    (topology.GetTopoGeomElements(topo_geom))[1] AS topo 
              FROM %I.network
            ) AS net
            JOIN %I.edge_data AS edata
            ON net.topo = edata.edge_id
          )';
EXECUTE format(_sql,atopology,atopology);

--Log all splitted geometries
_sql := ' INSERT INTO %I.cleanup_errors (net_id, net_geom, edges_id, edges_geoms, err)
          (   
            SELECT net_id, 
                   net_geom, 
                   array_agg(edge_id) as edges, 
                   st_collect(array_agg(edge_geom)) as edgesgeom, 
                   ''split''::text
            FROM results 
            JOIN
            (
              SELECT net_id FROM results GROUP BY net_id HAVING  count(*) >1 
            ) AS split
            USING(net_id)
            GROUP BY  net_id ,net_geom
          )';
EXECUTE format(_sql, atopology);

-- Remove and log all duplicated edges.
-- INFO : duplicates are not kept in the cleaned network, resulting in a potential loss of data.

-- Use a temp table to save computation time.
_sql := 'CREATE TEMPORARY TABLE duplicates  
         ON COMMIT DROP 
         AS
         (
          SELECT  rnum, 
            net_id, 
            net_geom, 
            ARRAY[edge_id] AS edges_id, 
            st_collect(ARRAY[edge_geom]) AS edges_geoms, 
            ''duplicate''::text AS err
          FROM
          (
            SELECT row_number() OVER (PARTITION BY edge_id ORDER BY rnum) AS idup, * FROM  results
          ) AS dup
          WHERE idup >1
         )';
EXECUTE _sql;

_sql := 'INSERT INTO %I.cleanup_errors 
         (net_id, net_geom, edges_id, edges_geoms, err)
         SELECT net_id,
    net_geom,
    edges_id,
    edges_geoms,
    err FROM duplicates';
EXECUTE format(_sql, atopology);

_sql := 'DELETE FROM results 
         WHERE rnum IN (
                            SELECT rnum 
                            FROM duplicates 
                          )';
EXECUTE _sql;

-- Log and remove all 0-length edges
_sql := 'INSERT INTO %I.cleanup_errors 
  (net_id, net_geom, edges_id, edges_geoms, err)
  SELECT net_id, 
                   net_geom, 
                   ARRAY[edge_id] as edges, 
                   st_collect(ARRAY[edge_geom]) as edgesgeom, 
                   ''null-length''::text
   FROM results
   WHERE edgelen =0.0';
 EXECUTE format(_sql, atopology);
 
_sql := 'DELETE FROM results
   WHERE rnum IN (
       SELECT rnum
       FROM results
       WHERE edgelen=0.0
      )';
 EXECUTE _sql;

 --Finally export the cleaned results
 _sql := 'INSERT INTO %I.cleaned_network
     (edge_id, start_node, end_node, edge_geom, net_id)
     SELECT a.edge_id, 
      b.start_node, 
      b.end_node, 
      a.edge_geom,
      a.net_id
     FROM results AS a
     LEFT OUTER JOIN %I.edge_data AS b
     USING(edge_id)';
EXECUTE format(_sql, atopology,atopology);

IF report THEN
  SELECT count(*) FROM results WHERE NOT st_equals(net_geom,edge_geom) INTO report_nmod;
  SELECT count(*) FROM results GROUP BY net_id HAVING  count(*) >1  INTO report_nsplit;
  SELECT count(*) FROM duplicates INTO report_ndup;
  SELECT count(*) FROM results WHERE edgelen=0.0 INTO report_nnullen;

  _sql := 'SELECT count(*) FROM %I.network';
  EXECUTE format(_sql, atopology)
  INTO report_inputlines;

  _sql := 'SELECT count(*) FROM %I.cleaned_network';
  EXECUTE format(_sql, atopology)
  INTO report_outputlines;
  
  report_nsplit := coalesce(report_nsplit,0); -- The split detection query can return null.
  
  RAISE WARNING E'\n================================================\n
  NETWORK ''%.%'' CLEANUP REPORT\n
  Edges in the input network...%\n
  Edges in the cleaned network...%\n
  Modified geometries...%\n
  Network edges split...%\n
  Duplicated edges...%\n
  Null-length edges...%\n
  ================================================',
  input_schema, input_table, report_inputlines,report_outputlines,report_nmod,report_nsplit,report_ndup,report_nnullen;
  RETURN ARRAY[report_inputlines,report_outputlines,report_nmod,report_nsplit,report_ndup,report_nnullen];
END IF;

RETURN ARRAY[];  

END
$BODY$
  LANGUAGE plpgsql VOLATILE;
COMMENT ON FUNCTION net_cleanup_topology(varchar,varchar,varchar,varchar,varchar,double precision, boolean)
IS
'The function net_cleanup_topology() cleans the topology of an network stored as linestrings in a table.
 For now, only tables with single-column primary key are handled.';



/*========================================================================================================================
The function net_finalize_cleanup() finalize the export of a previously cleaned network in two steps:
(1) a copy of the original table is created in the cleanup schema.
(2) two columns containing the edge id (edge_id) and geom (edge_geom) in the topological network are added to the table.
@param atopology The topology schema where the cleaned network is located.
@param input_schema The schema containing the original table.
@param input_network The original table.
@param input_net_key_column The name of column containing the primary key in the original table (default is id).'
*/
CREATE OR REPLACE FUNCTION net_finalize_cleanup(
    atopology varchar,
    input_schema varchar,
    input_network varchar,
    input_net_key_column varchar)
  RETURNS void AS
$BODY$
DECLARE
  _sql text;
BEGIN
  RAISE DEBUG 'Start exporting table %.%',input_schema,input_network;
  
  -- Create the output edges
  EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I',atopology); 
  EXECUTE format('DROP TABLE IF EXISTS %I.%I', atopology, input_network);
  
  RAISE DEBUG 'Exporting table content';
  -- Create network edges with geometries that have not been splitted during the cleaning process
  _sql := 'CREATE TABLE %I.%I AS 
           SELECT b.edge_id, b.edge_geom, a.*
           FROM %I.%I AS a 
           JOIN %I.cleaned_network AS b
           ON a.%I = b.net_id';
  EXECUTE format(_sql,atopology, input_network,input_schema,input_network,atopology, input_net_key_column);
  
  _sql := 'SELECT Populate_Geometry_Columns(''%I.%I''::regclass)';
  EXECUTE format(_sql, atopology, input_network);

  -- Add spatial indexing
  _sql := 'CREATE INDEX tbl_%s_gist ON %I.%I USING gist(edge_geom)';
  EXECUTE format(_sql,input_network,atopology,input_network);
  RAISE DEBUG 'END';
END
$BODY$
  LANGUAGE plpgsql VOLATILE;
COMMENT ON FUNCTION net_finalize_cleanup(varchar,varchar,varchar,varchar)
IS
'The function net_finalize_cleanup() finalize the export of a previously cleaned network in two steps:
 (1) a copy of the original table is created in the cleanup schema.
 (2) two columns containing the edge id (edge_id) and geom (edge_geom) in the topological network are added to the table.
@param atopology The topology schema where the cleaned network is located.
@param input_schema The schema containing the original table.
@param input_network The original table.
@param input_net_key_column The name of column containing the primary key in the original table (default is id).';



/*==============================================================================================================
The function remote_net_cleanup() cleans the topology of a network table stored in a remote database.
For now, the export only works on network table with single-column primary keys.
If the cleaned (schema prefixed) table is XX.YY, the cleaned table will be named "cleaned_XX_YY.YY".
@param foreign_server The foreign server.
@param remote_schema The schema of the remote table to clean.
@param remote_tbl The name of the remote table to clean.
@param col_key The name of column containing the primary key of the remote table to clean (default is 'id').
@param col_geom The name of the geometric column of the table to clean (default is 'geom').
@param tolerance the threshold used to snap close points during the topological cleaning (default is 1.0m).
@param cleanup_report If TRUE, display a report of the topological cleanup.
*/
CREATE OR REPLACE FUNCTION remote_net_cleanup(
  foreign_server varchar,
  remote_schema varchar,
  remote_tbl varchar,
  col_key varchar = 'id',
  col_geom varchar = 'geom',
  tolerance double precision = 1.0,
  cleanup_report boolean = TRUE)
   RETURNS void AS
$BODY$
DECLARE
  topology_name text := 'cleaned_'||remote_schema||'_'||remote_tbl;
BEGIN
  RAISE DEBUG 'Started export of table %.%',remote_schema,remote_tbl;
  --Initial cleanup and preparation
  EXECUTE format('DROP SCHEMA IF EXISTS %I CASCADE',remote_schema); 
  EXECUTE format('CREATE SCHEMA %I',remote_schema);

  -- Import the foreign table. 
  --Because we don't know the list of its columns, we use IMPORT SCHEMA with a filter on this table 
  EXECUTE format('IMPORT FOREIGN SCHEMA %I LIMIT TO (%I) FROM SERVER %I INTO %I', remote_schema,remote_tbl,foreign_server,remote_schema);

  --Actually perform the topology cleanup
  PERFORM net_cleanup_topology(topology_name, remote_schema,remote_tbl,col_key, col_geom,tolerance,cleanup_report);
  PERFORM net_finalize_cleanup(topology_name,remote_schema, remote_tbl,col_key);
  
  -- Final cleanup. Do not drop the topology schema to allow for further operations on the generated topology.
  EXECUTE format('DROP SCHEMA IF EXISTS %I cascade',remote_schema); 

  RAISE DEBUG 'Export ended';
END
$BODY$
  LANGUAGE plpgsql VOLATILE;
COMMENT ON FUNCTION remote_net_cleanup(varchar,varchar,varchar,varchar,varchar,double precision,boolean)
IS
'The function remote_net_cleanup() cleans the topology of a network table stored in a remote database.
For now, the export only works on network table with single-column primary keys.
If the cleaned (schema prefixed) table is XX.YY, the cleaned table will be named "cleaned_XX_YY.YY".
@param foreign_server The foreign server.
@param remote_schema The schema of the remote table to clean.
@param remote_tbl The name of the remote table to clean.
@param col_key The name of column containing the primary key of the remote table to clean (default is id).
@param col_geom The name of the geometric column of the table to clean (default is geom).
@param tolerance the threshold used to snap close points during the topological cleaning (default is 1.0m).
@param cleanup_report If TRUE, display a report of the topological cleanup.
';

----------------------------------------------------
--  2. Create the wrapper to the remote database
----------------------------------------------------
DROP SERVER IF EXISTS foreign_db CASCADE;
CREATE SERVER foreign_db FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host :rhost, dbname :rdb, port :rport);
CREATE USER MAPPING FOR current_user SERVER foreign_db OPTIONS (user :ruser, password :rpwd);