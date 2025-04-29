public class MonthlyRevenueEventServiceChapter5 {
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

    // 1) Delete existing MREs
    List<Monthly_Revenue_Event__c> existingMREs = [
      SELECT Id
      FROM Monthly_Revenue_Event__c
      WHERE Opportunity__c = :opp.Id
    ];
    if (!existingMREs.isEmpty()) {
      delete existingMREs;
      System.debug('Deleted ' + existingMREs.size() + ' existing MRE records.');
    }

    // 2) Exit if not Closed Won or Closed Lost
    if (opp.StageName != 'Closed Won' && opp.StageName != 'Closed Lost') {
      return;
    }

    // Also do nothing if it's a Closed Lost Upsell
    if (opp.RecordType.Name == 'Upsell' && opp.StageName == 'Closed Lost') {
      return;
    }

    // 3) If it’s a renewal, query the original Opp
    Opportunity originalOpp = (opp.Renewal_Of__c != null)
      ? [
          SELECT Id, MRR__c, Total_Amendment_ARR__c
          FROM Opportunity
          WHERE Id = :opp.Renewal_Of__c
          LIMIT 1
        ]
      : null;

    // Prepare MRE list
    List<Monthly_Revenue_Event__c> mreList = new List<Monthly_Revenue_Event__c>();
    Boolean skipMonthlyLoop = false;

    // 4) Handle Closed Lost Renewals -> CHURN
    if (opp.StageName == 'Closed Lost' && opp.Renewal_Of__c != null) {
      Opportunity parentOpp = [
        SELECT Id, MRR__c
        FROM Opportunity
        WHERE Id = :opp.Renewal_Of__c
        LIMIT 1
      ];
      if (parentOpp != null) {
        Decimal parentMRR = parentOpp.MRR__c;

        // Add CHURN MRE
        mreList.add(
          createMRE(opp, opp.Contract_Start_Date__c, 'CHURN', -parentMRR)
        );
        // Add offsetting MRR to net to zero
        mreList.add(
          createMRE(opp, opp.Contract_Start_Date__c, 'MRR', parentMRR)
        );
      }
      skipMonthlyLoop = true; // Don’t generate monthly MRR if it’s CHURN
    }

    // 5) If not skipping, generate monthly MRR events
    if (!skipMonthlyLoop) {
      Date startDate = opp.Contract_Start_Date__c;
      Integer contractMons = opp.Contract_Term__c.intValue();

      for (Integer i = 0; i < contractMons; i++) {
        // Safely add i months
        Date baseDate = startDate.addMonths(i);
        Integer daysInMo = Date.daysInMonth(baseDate.year(), baseDate.month());
        Integer dayToUse = Math.min(startDate.day(), daysInMo);
        Date currentMonth = Date.newInstance(
          baseDate.year(),
          baseDate.month(),
          dayToUse
        );

        if (i == 0) {
          handleFirstMonthRevenue(opp, originalOpp, currentMonth, mreList);
        } else {
          mreList.add(createMRE(opp, currentMonth, 'MRR', opp.MRR__c));
        }
      }
    }

    // 6) Insert all MREs, then update Cohorts
    if (!mreList.isEmpty()) {
      insert mreList;
      System.debug(
        'Inserted ' + mreList.size() + ' Monthly Revenue Event records.'
      );

      // Check if this Opportunity is the *root* Opp, and it’s Closed Won
      Id rootOppId = getRootOppId(opp);
      if (opp.Id == rootOppId && opp.StageName == 'Closed Won') {
        // Only do Cohort aggregator for the root Opp
        updateCohortsForMREs(mreList);
      }
    }
  }

  /**
   * For the *first month* in the contract (or a renewal),
   * decides whether to label MRR as NEW, UP, DOWN, etc.
   */
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
        mreList.add(createMRE(opp, currentMonth, 'DOWN', deltaAmount)); // negative
        mreList.add(createMRE(opp, currentMonth, 'MRR', originalOpp.MRR__c));
      } else {
        // flat renewal
        mreList.add(createMRE(opp, currentMonth, 'MRR', opp.MRR__c));
      }
    } else if (opp.RecordType.Name == 'Upsell') {
      mreList.add(createMRE(opp, currentMonth, 'UP', opp.MRR__c));
    } else {
      // brand new Opp
      mreList.add(createMRE(opp, currentMonth, 'NEW', opp.MRR__c));
    }
  }

  /**
   * Creates a Monthly_Revenue_Event__c, linking it to a Cohort record
   * determined by the **root** Opportunity’s Contract Start Date.
   */
  private static Monthly_Revenue_Event__c createMRE(
    Opportunity opp,
    Date month,
    String type,
    Decimal amount
  ) {
    // 1) Find the root Opp
    Id rootOppId = getRootOppId(opp);
    Opportunity rootOpp = [
      SELECT Id, Contract_Start_Date__c
      FROM Opportunity
      WHERE Id = :rootOppId
      LIMIT 1
    ];

    // 2) Use that date (fallback to the MRE’s month if null)
    Date rootStart = (rootOpp != null &&
      rootOpp.Contract_Start_Date__c != null)
      ? rootOpp.Contract_Start_Date__c
      : month;

    // 3) Cohort Name from root Opp’s start date (YYYY-MM)
    String cohortName =
      rootStart.year() +
      '-' +
      (rootStart.month() < 10
        ? '0' + rootStart.month()
        : String.valueOf(rootStart.month()));

    // 4) See if that Cohort already exists
    Cohort__c cohort;
    List<Cohort__c> existing = [
      SELECT Id
      FROM Cohort__c
      WHERE Name = :cohortName
      LIMIT 1
    ];
    if (!existing.isEmpty()) {
      cohort = existing[0];
    } else {
      // Create a new Cohort record
      cohort = new Cohort__c(Name = cohortName, Cohort_Start_Amount__c = 0);
      insert cohort;
    }

    // 5) Return a new MRE that points to that single Cohort
    return new Monthly_Revenue_Event__c(
      Account__c = opp.AccountId,
      Opportunity__c = opp.Id,
      Root_Opportunity__c = rootOppId,
      Month__c = month,
      Type__c = type,
      Amount__c = amount,
      Cohort__c = cohort.Id
    );
  }

  /**
   * Updates the existing Cohort__c records for the newly inserted MREs
   * by *summing* the MRE amounts for each Cohort link.
   */
  private static void updateCohortsForMREs(
    List<Monthly_Revenue_Event__c> mreList
  ) {
    // Only sum these “start” types into Cohort_Start_Amount__c:
    Set<String> startTypes = new Set<String>{ 'NEW', 'UP', 'DOWN', 'CHURN' };

    // Map<cohortId -> sum of relevant MRE amounts we just inserted
    Map<Id, Decimal> newAmountsByCohort = new Map<Id, Decimal>();

    for (Monthly_Revenue_Event__c mre : mreList) {
      // Skip if no cohort or if this MRE is pure “MRR”
      if (mre.Cohort__c == null)
        continue;
      if (!startTypes.contains(mre.Type__c))
        continue;

      if (!newAmountsByCohort.containsKey(mre.Cohort__c)) {
        newAmountsByCohort.put(mre.Cohort__c, 0);
      }
      newAmountsByCohort.put(
        mre.Cohort__c,
        newAmountsByCohort.get(mre.Cohort__c) + mre.Amount__c
      );
    }

    if (newAmountsByCohort.isEmpty()) {
      // No changes needed
      return;
    }

    // Query existing cohorts to retrieve their current amounts
    Map<Id, Cohort__c> existingCohorts = new Map<Id, Cohort__c>(
      [
        SELECT Id, Cohort_Start_Amount__c
        FROM Cohort__c
        WHERE Id IN :newAmountsByCohort.keySet()
      ]
    );

    // Update the cohorts with the *added* value
    List<Cohort__c> cohortsToUpdate = new List<Cohort__c>();
    for (Id cohortId : newAmountsByCohort.keySet()) {
      Cohort__c c = existingCohorts.get(cohortId);
      if (c != null) {
        Decimal oldAmount = (c.Cohort_Start_Amount__c == null)
          ? 0
          : c.Cohort_Start_Amount__c;
        Decimal newAmount = oldAmount + newAmountsByCohort.get(cohortId);
        c.Cohort_Start_Amount__c = newAmount;
        cohortsToUpdate.add(c);
      }
    }

    if (!cohortsToUpdate.isEmpty()) {
      update cohortsToUpdate;
      System.debug('Updated Cohort records: ' + cohortsToUpdate.size());
    }
  }

  /**
   * Returns the topmost Opportunity in the chain (root Opp).
   * This method is the same as before, included for completeness.
   */
  private static Id getRootOppId(Opportunity opp) {
    if (opp == null) {
      return null;
    }
    // 1) If Upsell + Amendment, follow to its parent
    Opportunity effectiveOpp = opp;
    if (opp.RecordType.Name == 'Upsell' && opp.Amendment_Of__c != null) {
      Opportunity parentAmendOpp = [
        SELECT Id, Renewal_Of__c, Amendment_Of__c
        FROM Opportunity
        WHERE Id = :opp.Amendment_Of__c
        LIMIT 1
      ];
      if (parentAmendOpp != null) {
        effectiveOpp = parentAmendOpp;
      }
    }
    // 2) Climb up the Renewal_Of__c chain
    Id currentId = effectiveOpp.Id;
    Id parentId = effectiveOpp.Renewal_Of__c;
    while (parentId != null) {
      Opportunity parentOpp = [
        SELECT Id, Renewal_Of__c
        FROM Opportunity
        WHERE Id = :parentId
        LIMIT 1
      ];
      if (parentOpp == null) {
        break;
      }
      currentId = parentOpp.Id;
      parentId = parentOpp.Renewal_Of__c;
    }
    return currentId;
  }
}
