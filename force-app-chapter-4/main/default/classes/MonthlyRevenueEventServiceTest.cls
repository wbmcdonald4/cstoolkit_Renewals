@isTest
public class MonthlyRevenueEventServiceTest {
  @testSetup
  static void setupTestData() {
    // Create Account
    Account testAccount = new Account(Name = 'Test Account');
    insert testAccount;

    // Retrieve Record Types
    Map<String, Id> recordTypeMap = new Map<String, Id>();
    for (RecordType rt : [
      SELECT Id, Name
      FROM RecordType
      WHERE SObjectType = 'Opportunity'
    ]) {
      recordTypeMap.put(rt.Name, rt.Id);
    }

    System.assert(
      recordTypeMap.containsKey('Sales'),
      'Sales Record Type should exist.'
    );
    System.assert(
      recordTypeMap.containsKey('Upsell'),
      'Upsell Record Type should exist.'
    );
    System.assert(
      recordTypeMap.containsKey('Renewal'),
      'Renewal Record Type should exist.'
    );

    // Create a Closed Won Sales Opportunity (Standard Case)
    Opportunity salesOpp = new Opportunity(
      Name = 'Closed Won Sales Opportunity',
      AccountId = testAccount.Id,
      StageName = 'Closed Won',
      CloseDate = Date.today(),
      Contract_Start_Date__c = Date.today(),
      Contract_Term__c = 12,
      Amount = 12000,
      RecordTypeId = recordTypeMap.get('Sales')
    );
    insert salesOpp;

    // Create a Closed Lost Renewal Opportunity
    Opportunity closedLostRenewal = new Opportunity(
      Name = 'Closed Lost Renewal Opportunity',
      AccountId = testAccount.Id,
      StageName = 'Closed Lost',
      CloseDate = Date.today(),
      Contract_Start_Date__c = Date.today(),
      Contract_Term__c = 12,
      Amount = 12000,
      Renewal_Of__c = salesOpp.Id,
      RecordTypeId = recordTypeMap.get('Renewal')
    );
    insert closedLostRenewal;

    // Create an Upsell Opportunity (Closed Won)
    Opportunity upsellOpp = new Opportunity(
      Name = 'Closed Won Upsell Opportunity',
      AccountId = testAccount.Id,
      StageName = 'Closed Won',
      CloseDate = Date.today(),
      Contract_Start_Date__c = Date.today(),
      Contract_Term__c = 6,
      Amount = 6000,
      RecordTypeId = recordTypeMap.get('Upsell')
    );
    insert upsellOpp;

    // Create a Closed Lost Upsell Opportunity (should not generate MREs)
    Opportunity closedLostUpsell = new Opportunity(
      Name = 'Closed Lost Upsell Opportunity',
      AccountId = testAccount.Id,
      StageName = 'Closed Lost',
      CloseDate = Date.today(),
      Contract_Start_Date__c = Date.today(),
      Contract_Term__c = 6,
      Amount = 6000,
      RecordTypeId = recordTypeMap.get('Upsell')
    );
    insert closedLostUpsell;

    // Create an Opportunity with Missing Fields (should be skipped)
    Opportunity missingFieldsOpp = new Opportunity(
      Name = 'Missing Fields Opportunity',
      AccountId = testAccount.Id,
      StageName = 'Closed Won',
      CloseDate = Date.today(),
      RecordTypeId = recordTypeMap.get('Sales')
    );
    insert missingFieldsOpp;
  }

  @isTest
  static void testGenerateEventsForFlow() {
    // Retrieve test Opportunities
    List<Opportunity> opps = [SELECT Id, Name FROM Opportunity];
    Map<String, Id> oppMap = new Map<String, Id>();
    for (Opportunity opp : opps) {
      oppMap.put(opp.Name, opp.Id);
    }

    List<MonthlyRevenueEventService.InputWrapper> inputList = new List<MonthlyRevenueEventService.InputWrapper>();

    // Add all opportunities to test different cases
    for (String oppName : oppMap.keySet()) {
      MonthlyRevenueEventService.InputWrapper inputWrapper = new MonthlyRevenueEventService.InputWrapper();
      inputWrapper.opportunityId = oppMap.get(oppName);
      inputList.add(inputWrapper);
    }

    // Run the invocable method
    Test.startTest();
    MonthlyRevenueEventService.generateEventsForFlow(inputList);
    Test.stopTest();

    // Verify that Monthly Revenue Events were created (excluding Closed Lost Upsell and Missing Fields Opp)
    List<Monthly_Revenue_Event__c> mreList = [
      SELECT Id
      FROM Monthly_Revenue_Event__c
    ];
    System.assert(
      mreList.size() > 0,
      'Monthly Revenue Events should be created.'
    );

    // Ensure no MREs were created for Closed Lost Upsell Opportunity
    List<Monthly_Revenue_Event__c> closedLostUpsellMREs = [
      SELECT Id
      FROM Monthly_Revenue_Event__c
      WHERE Opportunity__c = :oppMap.get('Closed Lost Upsell Opportunity')
    ];
    System.assertEquals(
      0,
      closedLostUpsellMREs.size(),
      'Closed Lost Upsell should not generate MREs.'
    );

    // Ensure no MREs were created for Missing Fields Opportunity
    List<Monthly_Revenue_Event__c> missingFieldsMREs = [
      SELECT Id
      FROM Monthly_Revenue_Event__c
      WHERE Opportunity__c = :oppMap.get('Missing Fields Opportunity')
    ];
    System.assertEquals(
      0,
      missingFieldsMREs.size(),
      'Opportunity with missing fields should not generate MREs.'
    );
  }
}
