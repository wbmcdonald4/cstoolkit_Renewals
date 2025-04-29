public class MonthlyRevenueEventService {
  /**
   * Wrapper class for invocable method input
   */
  public class InputWrapper {
    @InvocableVariable(required=true)
    public Id opportunityId; // Single Opportunity ID
  }

  /**
   * Invocable method to generate Monthly Revenue Events
   * @param input - List of InputWrapper containing Opportunity IDs
   */
  @InvocableMethod(
    label='Generate Monthly Revenue Events'
    description='Generate Monthly Revenue Events for a single Closed Won Opportunity'
  )
  public static void generateEventsForFlow(List<InputWrapper> input) {
    // Extract Opportunity IDs from the input
    Set<Id> opportunityIds = new Set<Id>();
    for (InputWrapper wrapper : input) {
      opportunityIds.add(wrapper.opportunityId);
    }

    // Query the Opportunity
    Opportunity opp = [
      SELECT
        Id,
        AccountId,
        Contract_Start_Date__c,
        Contract_Term__c,
        MRR__c,
        Renewal_Of__c,
        StageName,
        Amendment_Of__c,
        RecordType.Name
      FROM Opportunity
      WHERE Id IN :opportunityIds
      LIMIT 1
    ];

    // Generate Monthly Revenue Events
    if (opp != null) {
      generateMonthlyRevenueEvents(opp);
    } else {
      System.debug('No valid Opportunity found for the provided ID.');
    }
  }

  /**
   * Generate Monthly Revenue Events for a single Opportunity
   * @param opp - The Opportunity record
   */
  private static void generateMonthlyRevenueEvents(Opportunity opp) {
    if (
      opp.Contract_Start_Date__c == null ||
      opp.Contract_Term__c == null ||
      opp.MRR__c == null
    ) {
      System.debug(
        'Opportunity lacks required fields to generate Monthly Revenue Events.'
      );
      return;
    }

    // Query and delete existing MRE records for this Opportunity
    List<Monthly_Revenue_Event__c> existingMREs = [
      SELECT Id
      FROM Monthly_Revenue_Event__c
      WHERE Opportunity__c = :opp.Id
    ];
    if (!existingMREs.isEmpty()) {
      delete existingMREs;
      System.debug(
        'Deleted ' +
          existingMREs.size() +
          ' existing Monthly Revenue Event records.'
      );
    }

    // If the Opp is not Closed Won or Closed Lost, exit without generating new MREs
    if (opp.StageName != 'Closed Won' && opp.StageName != 'Closed Lost') {
      return;
    }

    // If the Opp is a Closed Lost upsell, do nothing
    if (opp.RecordType.Name == 'Upsell' && opp.StageName == 'Closed Lost') {
      return;
    }

    // Handle Closed Lost Renewals
    if (opp.StageName == 'Closed Lost' && opp.Renewal_Of__c != null) {
      Opportunity parentOpp = [
        SELECT Id, MRR__c
        FROM Opportunity
        WHERE Id = :opp.Renewal_Of__c
        LIMIT 1
      ];
      if (parentOpp != null) {
        Decimal parentMRR = parentOpp.MRR__c;
        // 1) Negative "CHURN" record
        insert new Monthly_Revenue_Event__c(
          Account__c = opp.AccountId,
          Opportunity__c = opp.Id,
          Month__c = opp.Contract_Start_Date__c,
          Type__c = 'CHURN',
          Amount__c = -parentMRR
        );

        // 2) Positive "MRR" record, to net to zero
        insert new Monthly_Revenue_Event__c(
          Account__c = opp.AccountId,
          Opportunity__c = opp.Id,
          Month__c = opp.Contract_Start_Date__c,
          Type__c = 'MRR',
          Amount__c = parentMRR
        );
      }
      return; // Exit early; no other MREs needed
    }

    // Query original Opportunity if this is a renewal
    Opportunity originalOpp = (opp.Renewal_Of__c != null)
      ? [
          SELECT Id, MRR__c, Total_Amendment_ARR__c
          FROM Opportunity
          WHERE Id = :opp.Renewal_Of__c
          LIMIT 1
        ]
      : null;

    // Prepare list to store Monthly Revenue Events
    List<Monthly_Revenue_Event__c> mreList = new List<Monthly_Revenue_Event__c>();

    // Calculate contract duration and loop through months
    Date startDate = opp.Contract_Start_Date__c;
    Integer contractMonths = opp.Contract_Term__c.intValue();

    for (Integer i = 0; i < contractMonths; i++) {
      // First, add i months to the original start date
      Date baseDate = startDate.addMonths(i);
      // Find the actual number of days in that new month
      Integer daysInMo = Date.daysInMonth(baseDate.year(), baseDate.month());
      // Decide which day to use: either the original day or the max day in the month
      Integer dayToUse = Math.min(startDate.day(), daysInMo);

      // Construct the “currentMonth” date safely
      Date currentMonth = Date.newInstance(
        baseDate.year(),
        baseDate.month(),
        dayToUse
      );

      // Continue as before
      if (i == 0) {
        handleFirstMonthRevenue(opp, originalOpp, currentMonth, mreList);
      } else {
        mreList.add(createMRE(opp, currentMonth, 'MRR', opp.MRR__c));
      }
    }

    if (!mreList.isEmpty()) {
      insert mreList;
      System.debug(
        'Inserted ' + mreList.size() + ' Monthly Revenue Event records.'
      );
    }
  }

  private static void handleFirstMonthRevenue(
    Opportunity opp,
    Opportunity originalOpp,
    Date currentMonth,
    List<Monthly_Revenue_Event__c> mreList
  ) {
    if (originalOpp != null) {
      Decimal totalAmendmentARR = (originalOpp.Total_Amendment_ARR__c == null)
        ? 0
        : originalOpp.Total_Amendment_ARR__c;
      Decimal deltaAmount =
        opp.MRR__c - (originalOpp.MRR__c + (totalAmendmentARR / 12));

      if (deltaAmount > 0) {
        mreList.add(createMRE(opp, currentMonth, 'UP', deltaAmount));
        mreList.add(createMRE(opp, currentMonth, 'MRR', originalOpp.MRR__c));
      } else if (deltaAmount < 0) {
        mreList.add(createMRE(opp, currentMonth, 'DOWN', deltaAmount)); // Negative for downsell
        mreList.add(createMRE(opp, currentMonth, 'MRR', originalOpp.MRR__c));
      } else {
        mreList.add(createMRE(opp, currentMonth, 'MRR', opp.MRR__c)); // handles flat renewals
      }
    } else if (opp.RecordType.Name == 'Upsell') {
      mreList.add(createMRE(opp, currentMonth, 'UP', opp.MRR__c));
    } else {
      mreList.add(createMRE(opp, currentMonth, 'NEW', opp.MRR__c));
    }
  }

  private static Monthly_Revenue_Event__c createMRE(
    Opportunity opp,
    Date month,
    String type,
    Decimal amount
  ) {
    return new Monthly_Revenue_Event__c(
      Account__c = opp.AccountId,
      Opportunity__c = opp.Id,
      Month__c = month,
      Type__c = type,
      Amount__c = amount
    );
  }
}
