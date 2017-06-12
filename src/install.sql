CREATE SCHEMA IF NOT EXISTS assert;
CREATE SCHEMA IF NOT EXISTS testpg;


CREATE TYPE testpg.test_result AS
(
  test_name character varying,
  successful boolean,
  failed boolean,
  errorneous boolean,
  error_message character varying,
  duration interval
);


--
-- Use select * from testpg.run_all() to execute all test cases
--
CREATE OR REPLACE FUNCTION testpg.run_all() RETURNS SETOF testpg.test_result
    LANGUAGE 'plpgsql'
AS $function$
BEGIN
  RETURN query SELECT * FROM testpg.run_suite(NULL);
END;
$function$;


--
-- Executes all test cases part of a suite and returns the test results.
--
-- Each test case will have a setup procedure run first, then a precondition,
-- then the test itself, followed by a postcondition and a tear down.
--
-- The test case stored procedure name has to match 'test_case_<p_suite>%' patern.
-- It is assumed the setup and precondition procedures are in the same schema as
-- the test stored procedure.
--
-- select * from testpg.run_suite('my_test'); will run all tests that will have
-- 'test_case_my_test' prefix.
CREATE OR REPLACE FUNCTION testpg.run_suite(p_suite text) RETURNS SETOF testpg.test_result
    LANGUAGE 'plpgsql'
AS $function$
DECLARE
  l_proc RECORD;
  l_sid INTEGER;
  l_row testpg.test_result%rowtype;
  l_start_ts timestamp;
  l_cmd text;
  l_condition text;
  l_precondition_cmd text;
  l_postcondition_cmd text;
BEGIN
  l_sid := pg_backend_pid();
  FOR l_proc IN SELECT p.proname, n.nspname
      FROM pg_catalog.pg_proc p
            JOIN pg_catalog.pg_namespace n ON p.pronamespace = n.oid
      WHERE p.proname like 'test/_case/_' || COALESCE(p_suite, '') || '%' escape '/'
      ORDER by p.proname LOOP
    -- check for setup
    l_condition := testpg.get_procname(l_proc.proname, 2, 'test_setup');
    IF l_condition IS NOT NULL THEN
      l_cmd := 'DO $body$ BEGIN PERFORM ' || quote_ident(l_proc.nspname) || '.' || quote_ident(l_condition)  || '(); END; $body$';
      PERFORM testpg.run_autonomous(l_cmd);
    END IF;
    l_row.test_name := quote_ident(l_proc.proname);
    -- check for precondition
    l_condition := testpg.get_procname(l_proc.proname, 2, 'test_precondition');
    IF l_condition IS NOT NULL THEN
      l_precondition_cmd := 'PERFORM testpg.run_condition(''' || quote_ident(l_proc.nspname) || '.' || quote_ident(l_condition) || '''); ';
    ELSE
      l_precondition_cmd := '';
    END IF;
    -- check for postcondition
    l_condition := testpg.get_procname(l_proc.proname, 2, 'test_postcondition');
    IF l_condition IS NOT NULL THEN
      l_postcondition_cmd := 'PERFORM testpg.run_condition(''' || quote_ident(l_proc.nspname) || '.' || quote_ident(l_condition) || '''); ';
    ELSE
      l_postcondition_cmd := '';
    END IF;
    -- execute the test
    l_start_ts := clock_timestamp();
    BEGIN
      l_cmd := 'DO $body$ BEGIN '
        || l_precondition_cmd
        || 'PERFORM ' || quote_ident(l_proc.nspname) || '.' || quote_ident(l_proc.proname)   || '(); '
        || l_postcondition_cmd
        || ' END; $body$';
      PERFORM testpg.run_autonomous(l_cmd);
      l_row.successful := true;
      l_row.failed := false;
      l_row.errorneous := false;
      l_row.error_message := 'OK';
    EXCEPTION
      WHEN triggered_action_exception then
        l_row.successful := false;
        l_row.failed := true;
        l_row.errorneous := false;
        l_row.error_message := SQLERRM;
      WHEN OTHERS THEN
        l_row.successful := false;
        l_row.failed := false;
        l_row.errorneous := true;
        l_row.error_message := SQLERRM;
    END;
    l_row.duration = clock_timestamp() - l_start_ts;
    RETURN NEXT l_row;
    -- check for teardown
    l_condition := testpg.get_procname(l_proc.proname, 2, 'test_teardown');
    IF l_condition IS NOT NULL THEN
      l_cmd := 'DO $body$ BEGIN PERFORM ' || quote_ident(l_proc.nspname) || '.' || quote_ident(l_condition)  || '(); END; $body$';
      PERFORM testpg.run_autonomous(l_cmd);
    END IF;
  END LOOP;
END;
$function$;


--
-- recreates a _ separated string from parts array
--
CREATE OR REPLACE FUNCTION testpg.build_procname(parts text[], p_from integer DEFAULT 1, p_to integer DEFAULT NULL::integer) RETURNS text
    LANGUAGE 'plpgsql'
    IMMUTABLE
AS $function$
DECLARE
  name TEXT := '';
  idx integer;
BEGIN
  IF p_to is null then
    p_to := array_length(parts, 1);
  END IF;
  name := parts[p_from];
  FOR idx IN (p_from + 1) .. p_to LOOP
    name := name || '_' || parts[idx];
  END LOOP;
  RETURN name;
END;
$function$;


--
-- Returns the procedure name matching the pattern below
--   <result_prefix>_<test_case_name>
-- Ex: result_prefix = test_setup and test_case_name = company_finance_invoice then it searches for:
--   test_setup_company_finance_invoice()
--   test_setup_company_finance()
--   test_setup_company()
--
-- It returns the name of the first stored procedure present in the database
--
CREATE OR REPLACE FUNCTION testpg.get_procname(test_case_name text, expected_name_count integer, result_prefix text) RETURNS text
    LANGUAGE 'plpgsql'
AS $function$
DECLARE
  array_name text[];
  array_proc text[];
  idx integer;
  len integer;
  proc_name text;
  is_valid integer;
BEGIN
  array_name := string_to_array(test_case_name, '_');
  len := array_length(array_name, 1);
  FOR idx IN expected_name_count + 1 .. len LOOP
    array_proc := array_proc || array_name[idx];
  END LOOP;

  len := array_length(array_proc, 1);
  FOR idx IN reverse len .. 1 LOOP
    proc_name := result_prefix || '_'  || testpg.build_procname(array_proc, 1, idx);
    SELECT 1 INTO is_valid FROM pg_catalog.pg_proc WHERE proname = proc_name;
    IF is_valid = 1 THEN
      RETURN proc_name;
    END IF;
  END LOOP;
  RETURN null;
END;
$function$;


CREATE OR REPLACE FUNCTION testpg.run_condition(proc_name text) RETURNS void
    LANGUAGE 'plpgsql'
AS $function$
DECLARE
  status boolean;
BEGIN
  EXECUTE 'select ' || proc_name || '()' INTO status;
  IF status THEN
    RETURN;
  END IF;
  RAISE EXCEPTION 'Condition failure: %()', proc_name USING errcode = 'triggered_action_exception';
END;
$function$;


CREATE OR REPLACE FUNCTION testpg.run_autonomous(p_statement character varying) RETURNS void
    LANGUAGE 'plpgsql'
AS $function$
DECLARE
  l_error_text character varying;
  l_error_detail character varying;
BEGIN
  RAISE EXCEPTION 'Exception Block Sub-transaction';
EXCEPTION
  WHEN OTHERS THEN
  BEGIN
    EXECUTE p_statement;
  EXCEPTION
    WHEN OTHERS THEN
      get stacked diagnostics l_error_text = message_text, l_error_detail = pg_exception_detail;
      RAISE EXCEPTION '%: Error on executing: % % %', sqlstate, p_statement, l_error_text, l_error_detail USING errcode = sqlstate;
  END;
END;
$function$;


--
-- Terminate all locked processes
--
CREATE OR REPLACE FUNCTION testpg.terminate(db character varying) RETURNS SETOF record
    LANGUAGE 'sql'
AS $function$
  SELECT pg_terminate_backend(pid), query
    FROM pg_stat_activity
    WHERE pid != pg_backend_pid() AND datname = db AND state = 'active';
$function$;


CREATE OR REPLACE FUNCTION assert.assert_true(message character varying, condition boolean) RETURNS void
    LANGUAGE 'plpgsql'
    IMMUTABLE
AS $function$
BEGIN
  IF NOT condition THEN
    RAISE EXCEPTION 'Assertion failure: %', message USING errcode = 'triggered_action_exception';
  END IF;
END;
$function$;


CREATE OR REPLACE FUNCTION assert.assert_true(condition boolean) RETURNS void
    LANGUAGE 'plpgsql'
    IMMUTABLE
AS $function$
BEGIN
  IF NOT condition THEN
    RAISE EXCEPTION 'Assertion failure: expression must be true' USING errcode = 'triggered_action_exception';
  END IF;
END;
$function$;


CREATE OR REPLACE FUNCTION assert.assert_false(message character varying, condition boolean) RETURNS void
    LANGUAGE 'plpgsql'
    IMMUTABLE
AS $function$
BEGIN
  IF NOT condition THEN
    RAISE EXCEPTION 'Assertion failure: %', message USING errcode = 'triggered_action_exception';
  END IF;
END;
$function$;


CREATE OR REPLACE FUNCTION assert.assert_false(condition boolean) RETURNS void
    LANGUAGE 'plpgsql'
    IMMUTABLE
AS $function$
BEGIN
  IF NOT condition THEN
    RAISE EXCEPTION 'Assertion failure: expression must be false' USING errcode = 'triggered_action_exception';
  END IF;
END;
$function$;


CREATE OR REPLACE FUNCTION assert.assert_not_null(character varying, anyelement) RETURNS void
    LANGUAGE 'plpgsql'
    IMMUTABLE
AS $function$
BEGIN
  IF $2 IS NULL THEN
    RAISE EXCEPTION 'Assertion failure: %', $1 USING errcode = 'triggered_action_exception';
  END IF;
END;
$function$;


CREATE OR REPLACE FUNCTION assert.assert_not_null(anyelement) RETURNS void
    LANGUAGE 'plpgsql'
    IMMUTABLE
AS $function$
BEGIN
  IF $1 IS NULL THEN
    RAISE EXCEPTION 'Assertion failure: argument must not be null' USING errcode = 'triggered_action_exception';
  END IF;
END;
$function$;


CREATE OR REPLACE FUNCTION assert.assert_null(character varying, anyelement) RETURNS void
    LANGUAGE 'plpgsql'
    IMMUTABLE
AS $function$
BEGIN
  IF $2 IS NOT NULL THEN
    RAISE EXCEPTION 'Assertion failure: %', $1 USING errcode = 'triggered_action_exception';
  END IF;
END;
$function$;


CREATE OR REPLACE FUNCTION assert.assert_null(anyelement) RETURNS void
    LANGUAGE 'plpgsql'
    IMMUTABLE
AS $function$
BEGIN
  IF $1 IS NOT NULL THEN
    RAISE EXCEPTION 'Assertion failure: argument must be null' USING errcode = 'triggered_action_exception';
  END IF;
END;
$function$;


CREATE OR REPLACE FUNCTION assert.assert_null(anyelement) RETURNS void
    LANGUAGE 'plpgsql'
    IMMUTABLE
AS $function$
BEGIN
  IF $1 IS NOT NULL THEN
    RAISE EXCEPTION 'Assertion failure: argument must be null' USING errcode = 'triggered_action_exception';
  END IF;
END;
$function$;


CREATE OR REPLACE FUNCTION assert.assert_equals(anyelement, anyelement) RETURNS void
    LANGUAGE 'plpgsql'
    IMMUTABLE
AS $function$
BEGIN
  IF $1 <> $2 THEN
    RAISE EXCEPTION 'Assertion failure: arguments must be equal' USING errcode = 'triggered_action_exception';
  END IF;
END;
$function$;


CREATE OR REPLACE FUNCTION assert.fail(character varying) RETURNS void
    LANGUAGE 'plpgsql'
    IMMUTABLE
AS $function$
BEGIN
  RAISE EXCEPTION 'Assertion failure: %', $1 USING errcode = 'triggered_action_exception';
END;
$function$;