@isTest
private class MonthlyRevenueEventServiceChapter5Test {
  /**
   * Test a new Opportunity in Stage Closed Won.
   * Expects MRE records to be generated (e.g. first MRE is "NEW").
   */
  @isTest
  static void testClosedWon_NewOpportunity() {
    // 1) Create an Account
    Account acc = new Account(Name = 'Test Account');
    insert acc;

    // 2) Create an Opp in Stage "Closed Won"
    //    We do NOT set MRR__c directly (it's read-only in your org).
    Opportunity opp = new Opportunity(
      Name = 'New Opp',
      AccountId = acc.Id,
      StageName = 'Closed Won',
      CloseDate = Date.today(),
      Contract_Start_Date__c = Date.today(),
      Contract_Term__c = 12,
      Amount = 1200,
      RecordTypeId = getDefaultRecordTypeId('Opportunity')
    );
    insert opp;

    // 3) Invoke the Flow method
    MonthlyRevenueEventServiceChapter5.InputWrapper inputWrap = new MonthlyRevenueEventServiceChapter5.InputWrapper();
    inputWrap.opportunityId = opp.Id;

    List<MonthlyRevenueEventServiceChapter5.InputWrapper> inputList = new List<MonthlyRevenueEventServiceChapter5.InputWrapper>{
      inputWrap
    };

    Test.startTest();
    MonthlyRevenueEventServiceChapter5.generateEventsForFlow(inputList);
    Test.stopTest();

    // 4) Verify MRE records
    List<Monthly_Revenue_Event__c> mreList = [
      SELECT Id, Type__c, Amount__c, Month__c, Cohort__c
      FROM Monthly_Revenue_Event__c
      WHERE Opportunity__c = :opp.Id
      ORDER BY CreatedDate ASC
    ];
    System.assert(
      !mreList.isEmpty(),
      'Should have created MRE records for a Closed Won Opp'
    );

    // For a brand-new Opp, the first record typically is "NEW"
    System.assertEquals(
      'NEW',
      mreList[0].Type__c,
      'First MRE should be NEW for a brand new Opp'
    );
  }

  /**
   * Test a Closed Lost Renewal. Expects two MREs: CHURN and offsetting MRR.
   */
  @isTest
  static void testClosedLostRenewal() {
    // Create root (older) Opp in Stage Closed Won
    Account acc = new Account(Name = 'Churn Test Account');
    insert acc;

    Opportunity originalOpp = new Opportunity(
      Name = 'Original Opp',
      AccountId = acc.Id,
      StageName = 'Closed Won',
      CloseDate = Date.today().addDays(-200),
      Contract_Start_Date__c = Date.today().addDays(-200),
      Contract_Term__c = 12,
      Amount = 600,
      RecordTypeId = getDefaultRecordTypeId('Opportunity')
    );
    insert originalOpp;

    // Renewal Opp in Stage "Closed Lost"
    Opportunity renewalOpp = new Opportunity(
      Name = 'Renewal Opp - Churn',
      AccountId = acc.Id,
      StageName = 'Closed Lost',
      CloseDate = Date.today(),
      Contract_Start_Date__c = Date.today(),
      Contract_Term__c = 12,
      Amount = 1200,
      Renewal_Of__c = originalOpp.Id,
      RecordTypeId = getDefaultRecordTypeId('Opportunity')
    );
    insert renewalOpp;

    // Call the Flow method
    MonthlyRevenueEventServiceChapter5.InputWrapper inputWrap = new MonthlyRevenueEventServiceChapter5.InputWrapper();
    inputWrap.opportunityId = renewalOpp.Id;

    Test.startTest();
    MonthlyRevenueEventServiceChapter5.generateEventsForFlow(
      new List<MonthlyRevenueEventServiceChapter5.InputWrapper>{ inputWrap }
    );
    Test.stopTest();

    // Verify that CHURN MRE exists
    List<Monthly_Revenue_Event__c> mreList = [
      SELECT Id, Type__c, Amount__c
      FROM Monthly_Revenue_Event__c
      WHERE Opportunity__c = :renewalOpp.Id
    ];
    System.assertEquals(
      2,
      mreList.size(),
      'Should have 2 MREs (CHURN and offsetting MRR).'
    );

    // Check that at least one MRE is CHURN
    Boolean hasChurn = false;
    for (Monthly_Revenue_Event__c rec : mreList) {
      if (rec.Type__c == 'CHURN') {
        hasChurn = true;
        break;
      }
    }
    System.assert(hasChurn, 'One MRE should be CHURN.');
  }

  /**
   * Test an Opp that is NOT in Closed Won or Closed Lost.
   * No MREs should be created.
   */
  @isTest
  static void testNotClosedWonOrLost() {
    // Create an Opp in "Prospecting"
    Account acc = new Account(Name = 'Prospecting Account');
    insert acc;

    Opportunity opp = new Opportunity(
      Name = 'Not Closed',
      AccountId = acc.Id,
      StageName = 'Prospecting',
      CloseDate = Date.today().addDays(15),
      Contract_Start_Date__c = Date.today(),
      Contract_Term__c = 12,
      Amount = 1200,
      RecordTypeId = getDefaultRecordTypeId('Opportunity')
    );
    insert opp;

    // Call the Flow method
    MonthlyRevenueEventServiceChapter5.InputWrapper inputWrap = new MonthlyRevenueEventServiceChapter5.InputWrapper();
    inputWrap.opportunityId = opp.Id;

    Test.startTest();
    MonthlyRevenueEventServiceChapter5.generateEventsForFlow(
      new List<MonthlyRevenueEventServiceChapter5.InputWrapper>{ inputWrap }
    );
    Test.stopTest();

    // Shouldn't create any MREs because it's neither Closed Won nor Lost
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Monthly_Revenue_Event__c
        WHERE Opportunity__c = :opp.Id
      ],
      'Should NOT create MREs if Opp is not Closed Won or Lost'
    );
  }

  /**
   * Helper method for retrieving a RecordType ID, if needed.
   * If you only have one record type, you can remove this
   * and omit RecordTypeId in your Opp creation.
   */
  private static Id getDefaultRecordTypeId(String sObjectName) {
    return [
      SELECT Id
      FROM RecordType
      WHERE SObjectType = :sObjectName
      LIMIT 1
    ]
    .Id;
  }
}
