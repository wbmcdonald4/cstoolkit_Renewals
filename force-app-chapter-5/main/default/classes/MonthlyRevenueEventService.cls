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
  @InvocableMethod(label='Generate Monthly Revenue Events' description='Generate Monthly Revenue Events for a single Closed Won Opportunity')
  public static void generateEventsForFlow(List<InputWrapper> input) {
      // Extract Opportunity IDs from the input
      Set<Id> opportunityIds = new Set<Id>();
      for (InputWrapper wrapper : input) {
          opportunityIds.add(wrapper.opportunityId);
      }

      // Query the Opportunity
      Opportunity opp = [
          SELECT Id, AccountId, Contract_Start_Date__c, Contract_Term__c, MRR__c, Renewal_Of__c, StageName, Amendment_Of__c, RecordType.Name
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
      if (opp.Contract_Start_Date__c == null || opp.Contract_Term__c == null || opp.MRR__c == null) {
          System.debug('Opportunity lacks required fields to generate Monthly Revenue Events.');
          return;
      }

      // Query and delete existing MRE records for this Opportunity
      List<Monthly_Revenue_Event__c> existingMREs = [
          SELECT Id FROM Monthly_Revenue_Event__c WHERE Opportunity__c = :opp.Id
      ];
      if (!existingMREs.isEmpty()) {
          delete existingMREs;
          System.debug('Deleted ' + existingMREs.size() + ' existing Monthly Revenue Event records.');
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
              SELECT Id, MRR__c FROM Opportunity WHERE Id = :opp.Renewal_Of__c LIMIT 1
          ];
          if (parentOpp != null) {
              Decimal parentMRR = parentOpp.MRR__c;
              Id rootOppId = getRootOppId(opp);
              // 1) Negative "CHURN" record
              insert new Monthly_Revenue_Event__c(
                Account__c           = opp.AccountId,
                Opportunity__c       = opp.Id,
                Root_Opportunity__c  = rootOppId,
                Month__c             = opp.Contract_Start_Date__c,
                Type__c              = 'CHURN',
                Amount__c            = -parentMRR
              );

              // 2) Positive "MRR" record, to net to zero
              insert new Monthly_Revenue_Event__c(
                  Account__c           = opp.AccountId,
                  Opportunity__c       = opp.Id,
                  Root_Opportunity__c  = rootOppId,
                  Month__c             = opp.Contract_Start_Date__c,
                  Type__c              = 'MRR',
                  Amount__c            = parentMRR
              );
          }
          return; // Exit early; no other MREs needed
      }

      // Query original Opportunity if this is a renewal
      Opportunity originalOpp = (opp.Renewal_Of__c != null) ? [
          SELECT Id, MRR__c, Total_Amendment_ARR__c FROM Opportunity WHERE Id = :opp.Renewal_Of__c LIMIT 1
      ] : null;

      // Prepare list to store Monthly Revenue Events
      List<Monthly_Revenue_Event__c> mreList = new List<Monthly_Revenue_Event__c>();

      // Calculate contract duration and loop through months
      Date startDate = opp.Contract_Start_Date__c;
      Date endDate = startDate.addMonths(opp.Contract_Term__c.intValue() - 1);

      for (Date currentMonth = startDate; currentMonth <= endDate; currentMonth = currentMonth.addMonths(1)) {
          if (currentMonth == startDate) {
              handleFirstMonthRevenue(opp, originalOpp, currentMonth, mreList);
          } else {
              mreList.add(createMRE(opp, currentMonth, 'MRR', opp.MRR__c));
          }
      }

      if (!mreList.isEmpty()) {
          insert mreList;
          System.debug('Inserted ' + mreList.size() + ' Monthly Revenue Event records.');
      }
  }

  private static void handleFirstMonthRevenue(
      Opportunity opp,
      Opportunity originalOpp,
      Date currentMonth,
      List<Monthly_Revenue_Event__c> mreList
  ) {
      if (originalOpp != null) {
          Decimal deltaAmount = opp.MRR__c - (originalOpp.MRR__c + (originalOpp.Total_Amendment_ARR__c / 12)); // Include (Amendment ARR / 12) in comparison

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

  private static Id getRootOppId(Opportunity opp) {
    // Edge case: null input
    if (opp == null) {
        return null;
    }

    // 1) If it's an Upsell with Amendment_Of__c, let's jump to that parent.
    //    (If you have multiple levels of amendments, you may need a loop or recursion here, too.)
    Opportunity effectiveOpp = opp;
    if (opp.RecordType.Name == 'Upsell' && opp.Amendment_Of__c != null) {
        Opportunity parentAmendOpp = [
            SELECT Id, Renewal_Of__c, Amendment_Of__c
            FROM Opportunity
            WHERE Id = :opp.Amendment_Of__c
            LIMIT 1
        ];
        // Now let's treat *that* parent as our starting point
        if (parentAmendOpp != null) {
            effectiveOpp = parentAmendOpp;
        }
    }

    // 2) Now climb the Renewal_Of__c chain from the "effectiveOpp"
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
            // Should not happen if the data is valid, but just in case
            break;
        }
        // Move up one level
        currentId = parentOpp.Id;
        parentId = parentOpp.Renewal_Of__c;
    }

    // currentId now points to the top-most Opp in the chain
    return currentId;
  }

  private static Monthly_Revenue_Event__c createMRE(Opportunity opp, Date month, String type, Decimal amount) {
      // Figure out the root Opp each time
      Id rootOppId = getRootOppId(opp);
      return new Monthly_Revenue_Event__c(
          Account__c = opp.AccountId,
          Opportunity__c = opp.Id,
          Root_Opportunity__c = rootOppId,
          Month__c = month,
          Type__c = type,
          Amount__c = amount
      );
  }
}
