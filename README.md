# testpg - Unit testing framework for PostgreSQL

Based on [PGUnit][#pgunit] testing framework to support unit tests as stored procedures without dependency on dblink. Try's to solve test isolation problem using exception block.
According to PostgreSQL documentation Functions and trigger procedures are always executed within a transaction established by an outer query — they cannot start or commit that transaction, since there would be no context for them to execute in.
However, a block containing an EXCEPTION clause effectively forms a subtransaction that can be rolled back without affecting the outer transaction.

Copy-paste from PGUnit documentation:
The testing is based on specific naming convention that allows automatic grouping of tests, setup, tear-downs, pre and post conditions.

Each unit test procedure name should have "test_case_" prefix in order to be identified as an unit test. Here is the comprehensive list of prefixes for all types:
- "test_case_": identifies an unit test procedure
- "test_precondition_": identifies a test precondition function
- "test_postcondition_": identifies a test postcondition  function
- "test_setup_": identifies a test setup procedure
- "test_teardown_": identifies a test tear down procedure.

For each test case the following 3 transactions are executed:
1. setup transaction: the setup procedure is searched based on the test name. If one is found it is executed in an autonomous transaction
2. unit test transaction: the pre and post condition functions are searched based on the test name; if they are found the autonomous transaction will be: if the precondition is true (default if one is not found) the unit test is ran, then the postcondition function is evaluated (true if one is not found). If any condition returns false the test is failed
3. tear down transaction: if a tear down procedure is found it is executed in an autonomous transaction indepedent of the unit test result.

An unit test execution can have 3 results: successful if the condition functions are true and the unit test procedure doesn't throw an exception, failed if there is an action exception triggered by a condition function or an assertion, and finally errornous if any other exception is triggered by any of the code above.

## Running one or more tests

To run the entire test suite the 'testpg.run_all' stored procedure needs to be used:
```sql
select testpg.run_all();
```
One can pick one or an entire group of tests based on their prefix using 'testpg.run_suite' stored procedure:
```sql
select testpg.run_suite('jsonb_merge');
```

## Assertion procedures

Scheme 'assert' provides set of asserting functions.

## Examples

Test case that checks if user is created by a stored procedure
```sql
create or replace function test_case_user_create_1() returns void as $$
declare
  id BIGINT;
begin
  SELECT customer.create_user(1, 100) INTO id;
  PERFORM assert.assert_not_null('user not created', id);
  PERFORM assert.assert_true('user id range improper', id >= 10000);
end;
$$ language plpgsql;
```

A precondition function for this test may be one checking for user id 1 being present into the database
```sql
create or replace function test_precondition_user() returns boolean as $$
declare
  id BIGINT;
begin
  SELECT user_id INTO id FROM customer.user WHERE user_id = 1;
  RETURN id IS NOT NULL AND (id = 1);
end;
$$ language plpgsql;
```
The precondition above will be shared on all 'user' tests unless one with a more specific name is created.

[#pgunit]: https://github.com/adrianandrei-ca/pgunit