/**
* @author Dr. Paul Coleman
* @date 2023-04-19
* @description A stand-alone Apex test for assessing scope of Account record type conversion
               to/from Person Accounts. The goal is the execution/debug log output at the
               bottom of the test, showing successes and failures of each account's
               conversion worthiness.
*/
@IsTest
private class PersonAccountConversionTest {

    /**
    * @author Dr. Paul Coleman & Kevin Zeigler. Salesforce.org
    * @date 2023-04-19
    * @description The code below runs a test against all data in an org within the boundaries
                    of a SOQL Select statement (variable `accountQuery` found under step 3]).
                    The test's default goal is to convert a business account record type to a
                    Person Account. But the code under step 1] can be modified to do the reverse
                    if the accountQuery also changes the WHERE clause to IsPersonAccount = TRUE
                    (as well as any other filter criteria desired).

                    Another variation might be to test more than the DML update limit of 10k records
                    by:
                    1st] remove/comment all code in the block below step 9], i.e. the actual DML
                         update to see if, after passing all other rules, the DML event actually
                         succeeds.
                    2nd] adjust the LIMIT clause at the end of `accountQuery` to the max, e.g. LIMIT 50000.
    */
    @IsTest( SeeAllData=true )
    static void testConvertingAccounts() {
        Test.startTest();
        System.runAs( [ SELECT Id FROM User WHERE IsActive = true AND Profile.Name = 'System Administrator' LIMIT 1 ][0] ) {
            Map<Id, String[]> errorsMap = new Map<Id, String[]>(); // holds error messages for each account id, if any
            Account[] accountsForUpdate = new Account[0]; // holds all accounts for conversion
            Map<Id, Id> contactIdToAccountIdMap = new Map<Id, Id>(); // used to do the final Contact lookup by ReportsToId

            // 1] get the target person account record type id
            Id paRecordTypeId = [ SELECT Id FROM RecordType WHERE isActive = TRUE AND isPersonType = TRUE LIMIT 1 ].Id;

            // 2] determine if multi-currency is enabled
            Boolean isMultiCurrencyEnabled = Account.sObjectType.getDescribe().fieldSets.getMap().containsKey( 'CurrencyISOCode' );

            // 3] adjust the initial account/contact query if multi-currency is not enabled
            String accountQuery = 'SELECT Id, IsCustomerPortal, OwnerId, CurrencyISOCode, ParentId, ' +
                    '(SELECT Id FROM ChildAccounts LIMIT 1), ' +
                    '(SELECT OwnerId, CurrencyISOCode, ReportsToId FROM Contacts) ' +
                    'FROM Account WHERE IsPersonAccount = FALSE LIMIT 10000';
            accountQuery = ( !isMultiCurrencyEnabled ? accountQuery.replaceAll( 'CurrencyISOCode, ', '' ) : accountQuery );

            // 4] Loop a query result of select accounts with related child records for evaluation (large data volume pattern)
            Integer totalCount = 0;
            for ( Account[] accounts : Database.query( accountQuery ) ) {
                for ( Account accnt : accounts )
                {
                    // 5] get the error message list for the current account id
                    String[] errorMsgs = errorsMap.containsKey( accnt.Id ) ? errorsMap.get( accnt.Id ) : new String[0];

                    // 6] begin evaluation of criteria that will not permit person account <=> business record type conversion
                    if ( accnt.IsCustomerPortal ) { // cannot be an external user identity
                        errorMsgs.add( 'Account cannot be bound to a User identity record.' );
                    }

                    if ( String.isNotEmpty( accnt.ParentId ) ) {  // no parent account
                        errorMsgs.add( 'Parent Account field on the Account is not blank.' );
                    }

                    if ( !accnt.ChildAccounts.isEmpty() ) {  // no child account hierarchy
                        errorMsgs.add( 'Account is set as a Parent Account for another account.' );
                    }

                    if( accnt.Contacts.size() == 1 )
                    {
                        Contact contct = accnt.Contacts[0];
                        if ( !contct.OwnerId.equals( accnt.OwnerId ) ) {  // matching owners
                            errorMsgs.add( 'Account and Contact have different record owners.' );
                        }

                        if ( String.isNotEmpty( contct.ReportsToId ) ) {   // no contact reporting parent
                            errorMsgs.add( 'ReportsTo field on the Contact is not blank.' );
                        }

                        if ( isMultiCurrencyEnabled )
                        {
                            if ( contct.get( 'CurrencyISOCode' ) != accnt.get( 'CurrencyISOCode' ) ) // matching currency
                            {
                                errorMsgs.add( 'Account and contact have different currency values.' );
                            }
                        }
                    } else {
                        errorMsgs.add( 'Account must have one and only one related Contact.' );
                    }


                    // if any errors were reported, add them to the map for final log output
                    if ( !errorMsgs.isEmpty() ) {
                        errorsMap.put( accnt.Id, errorMsgs );
                    } else { //ALL CLEAR for final eval of ReportsTo, add account and contact ids to map
                        contactIdToAccountIdMap.put( accnt.Contacts[0].Id, accnt.Id );
                    }

                    totalCount++;
                } // end account batch loop
            } // end account list loop

            // 7] for contact/account id pairs that were not disqualified, see if the Contact has child records via ReportsToId
            if ( !contactIdToAccountIdMap.isEmpty() ) {
                for ( Contact[] directReports : [ SELECT Id, AccountId, ReportsToId FROM Contact WHERE ReportsToId = :contactIdToAccountIdMap.keySet() ] ) {
                    for ( Contact c : directReports ) {
                        if ( contactIdToAccountIdMap.containsKey( c.ReportsToId ) )  // may have been deleted from the map if there are multiple direct reports
                        {
                            Id accountId = contactIdToAccountIdMap.get( c.ReportsToId ); // get account parenting the contact
                            String[] errors = errorsMap.containsKey( accountId ) ? errorsMap.get( accountId ) : new String[0];
                            errors.add( 'Contact is set as a Reports To for another contact(s).' ); // add error condition
                            errorsMap.put( accountId, errors );
                            contactIdToAccountIdMap.remove( c.ReportsToId ); // remove the contact/account id pair from the map
                        }
                    }
                }
            }

            // 8] for any remaining contact/account id pairs, assign the new recordtype for conversion
            for ( Id aCandidateForConversionId : contactIdToAccountIdMap.values() ) {
                accountsForUpdate.add( new Account( Id = aCandidateForConversionId, RecordTypeId = paRecordTypeId ) );
            }

            // 9] attempt to save the accounts with new record type ids, capture DML error results for the log
            Integer index = 0;
            Integer dmlErrorCount = 0;
            for ( Database.SaveResult result : Database.update( accountsForUpdate, false ) ) {
                if ( !result.success ) {
                    errorsMap.put( accountsForUpdate[index].Id, new String[]{ result.errors[0].message } );
                    dmlErrorCount++;
                }
                index++;
            }

            // 10] log all output for easy retrieval from the execution drain
            Map<String, String> logMap = new Map<String, String>();
            logMap.put( 'COUNT OF ACCOUNTS EVALUATED', String.valueOf( totalCount ) );
            logMap.put( 'COUNT OF QUALIFIED ACCOUNTS', String.valueOf( contactIdToAccountIdMap.size() ) );
            logMap.put( 'COUNT OF DML ERRORS', String.valueOf( dmlErrorCount ) + ' ' + String.valueOf( Math.ceil( ( dmlErrorCount / contactIdToAccountIdMap.size() ) * 100 ) ) + '%' );
            logMap.put( 'COUNT OF NON-DML ERRORS', String.valueOf( errorsMap.size() - dmlErrorCount ) );

            System.debug( LoggingLevel.WARN, JSON.serializePretty( logMap ) );
            System.debug( LoggingLevel.WARN, 'ALL ERROR MESSAGES:\n' + JSON.serializePretty( errorsMap ) );
        }
        Test.stopTest();
    }
}