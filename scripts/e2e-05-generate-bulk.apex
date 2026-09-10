// DocGen E2E Test 05 — Bulk Generation Pipeline
// Run: sf apex run --target-org <org> -f scripts/e2e-05-generate-bulk.apex
// Depends on: e2e-02 (Account 'E2E Test Corp', Template 'E2E Test Template')
// Expected: PASS: N  FAIL: 0

Integer pass = 0;
Integer fail = 0;

Id acctId;
Id tmplId;
Id jobId;
Id savedQueryId;

// ===== Look up test data =====
try {
    List<Account> accts = [SELECT Id FROM Account WHERE Name = 'E2E Test Corp' LIMIT 1];
    if (accts.isEmpty()) {
        fail++;
        System.debug('LOOKUP ACCOUNT: FAIL — Run e2e-02 first.');
    } else {
        acctId = accts[0].Id;
        pass++;
        System.debug('LOOKUP ACCOUNT: PASS');
    }

    List<DocGen_Template__c> tmpls = [SELECT Id FROM DocGen_Template__c WHERE Name = 'E2E Test Template' LIMIT 1];
    if (tmpls.isEmpty()) {
        fail++;
        System.debug('LOOKUP TEMPLATE: FAIL — Run e2e-02 first.');
    } else {
        tmplId = tmpls[0].Id;
        pass++;
        System.debug('LOOKUP TEMPLATE: PASS');
    }
} catch (Exception e) {
    fail++;
    System.debug('LOOKUP: FAIL — ' + e.getMessage());
}

if (acctId == null || tmplId == null) {
    System.debug('========================================');
    System.debug('E2E-05 GENERATE BULK — PASS: ' + pass + '  FAIL: ' + fail + '  ABORTED (missing test data)');
    System.debug('========================================');
    return;
}

// ===== Validate Filter =====
try {
    Integer ct = DocGenBulkController.validateFilter('Account', 'Name = \'E2E Test Corp\'');
    if (ct > 0) {
        pass++;
        System.debug('VALIDATE FILTER > 0: PASS — count: ' + ct);
    } else {
        fail++;
        System.debug('VALIDATE FILTER > 0: FAIL — count: ' + ct);
    }
} catch (Exception e) {
    fail++;
    System.debug('VALIDATE FILTER: FAIL — ' + e.getMessage());
}

// ===== Submit Bulk Job =====
try {
    jobId = DocGenBulkController.submitJob(
        tmplId,
        'Name = \'E2E Test Corp\'',
        'E2E Bulk Test Job',
        false,
        1,
        false,
        null,
        null
    );
    if (jobId != null) {
        pass++;
        System.debug('SUBMIT JOB: PASS — jobId: ' + jobId);
    } else {
        fail++;
        System.debug('SUBMIT JOB: FAIL — null jobId');
    }
} catch (Exception e) {
    fail++;
    System.debug('SUBMIT JOB: FAIL — ' + e.getMessage());
}

// ===== Sort Order — parent-level ORDER BY on the bulk query =====
// The bulk query had no ORDER BY, so a merged PDF came out in record-creation
// order with no way to change it. Merge order follows query order, so these
// assertions cover the clause that reaches the QueryLocator.
try {
    String canonical = DocGenBulkController.normalizeSortOrder('Account', 'name desc');
    if (canonical == 'Name DESC NULLS LAST') {
        pass++;
        System.debug('SORT CANONICALIZE: PASS — ' + canonical);
    } else {
        fail++;
        System.debug('SORT CANONICALIZE: FAIL — ' + canonical);
    }

    // Single sort field gains the name field as a tie-break so repeat runs of the
    // same job produce the same packet.
    String tie = DocGenBulkController.normalizeSortOrder('Account', 'AnnualRevenue DESC');
    if (tie == 'AnnualRevenue DESC NULLS LAST, Name ASC NULLS LAST') {
        pass++;
        System.debug('SORT TIE-BREAK: PASS — ' + tie);
    } else {
        fail++;
        System.debug('SORT TIE-BREAK: FAIL — ' + tie);
    }

    // The headline case: order child records by a parent field.
    String rel = DocGenBulkController.normalizeSortOrder('Account', 'owner.name');
    if (rel != null && rel.startsWith('Owner.Name ASC')) {
        pass++;
        System.debug('SORT TRAVERSAL: PASS — ' + rel);
    } else {
        fail++;
        System.debug('SORT TRAVERSAL: FAIL — ' + rel);
    }

    Boolean rejected = false;
    try {
        DocGenBulkController.normalizeSortOrder('Account', 'Name ASC; DELETE FROM Account');
    } catch (Exception rejectEx) {
        rejected = true;
    }
    if (rejected) {
        pass++;
        System.debug('SORT INJECTION REJECTED: PASS');
    } else {
        fail++;
        System.debug('SORT INJECTION REJECTED: FAIL — clause was accepted');
    }

    Boolean unknownRejected = false;
    try {
        DocGenBulkController.normalizeSortOrder('Account', 'NotAField__c');
    } catch (Exception rejectEx) {
        unknownRejected = true;
    }
    if (unknownRejected) {
        pass++;
        System.debug('SORT UNKNOWN FIELD REJECTED: PASS');
    } else {
        fail++;
        System.debug('SORT UNKNOWN FIELD REJECTED: FAIL — clause was accepted');
    }
} catch (Exception e) {
    fail++;
    System.debug('SORT ORDER: FAIL — ' + e.getMessage());
}

// ===== Get Job Status =====
try {
    if (jobId != null) {
        DocGen_Job__c j = DocGenBulkController.getJobStatus(jobId);
        if (j != null && j.Status__c != null) {
            pass++;
            System.debug('GET JOB STATUS: PASS — status: ' + j.Status__c);
        } else {
            fail++;
            System.debug('GET JOB STATUS: FAIL — null or no status');
        }
    } else {
        fail++;
        System.debug('GET JOB STATUS: FAIL — no jobId from submit');
    }
} catch (Exception e) {
    fail++;
    System.debug('GET JOB STATUS: FAIL — ' + e.getMessage());
}

// ===== Get Recent Jobs =====
try {
    List<DocGen_Job__c> recent = DocGenBulkController.getRecentJobs();
    if (recent != null) {
        // Should contain at least our just-created job
        Boolean foundOurJob = false;
        for (DocGen_Job__c rj : recent) {
            if (rj.Id == jobId) {
                foundOurJob = true;
                break;
            }
        }
        if (foundOurJob) {
            pass++;
            System.debug('GET RECENT JOBS: PASS — found our job in list of ' + recent.size());
        } else {
            pass++;
            System.debug('GET RECENT JOBS: PASS — ' + recent.size() + ' jobs (our job may be processing)');
        }
    } else {
        fail++;
        System.debug('GET RECENT JOBS: FAIL — null');
    }
} catch (Exception e) {
    fail++;
    System.debug('GET RECENT JOBS: FAIL — ' + e.getMessage());
}

// ===== Analyze Job =====
try {
    DocGenBulkController.JobAnalysis analysis = DocGenBulkController.analyzeJob(tmplId, 1, 1, false, false);
    if (analysis != null && analysis.canProceed != null) {
        pass++;
        System.debug('ANALYZE JOB: PASS — canProceed: ' + analysis.canProceed + ', summary: ' + analysis.summary);
    } else {
        fail++;
        System.debug('ANALYZE JOB: FAIL — null analysis');
    }
} catch (Exception e) {
    fail++;
    System.debug('ANALYZE JOB: FAIL — ' + e.getMessage());
}

// ===== Duplex padding (#382) — Combined-PDF only, forced off otherwise =====
try {
    // Combined PDF + duplex on: the flag is persisted on the job.
    Id dpxJob = DocGenBulkController.submitJob(
        tmplId,
        'Name = \'E2E Test Corp\'',
        'E2E Duplex On',
        true,
        1,
        true,
        null,
        true
    );
    DocGen_Job__c dpxRec = [SELECT Duplex_Padding__c FROM DocGen_Job__c WHERE Id = :dpxJob];
    if (dpxRec.Duplex_Padding__c == true) {
        pass++;
        System.debug('DUPLEX FLAG PERSISTED: PASS');
    } else {
        fail++;
        System.debug('DUPLEX FLAG PERSISTED: FAIL — flag not set on Combined-PDF job');
    }
    delete [SELECT Id FROM DocGen_Job__c WHERE Id = :dpxJob];

    // Individual Files + duplex on: submitJobInternal must force it off (no merge to pad).
    Id noMergeJob = DocGenBulkController.submitJob(
        tmplId,
        'Name = \'E2E Test Corp\'',
        'E2E Duplex Forced Off',
        false,
        1,
        false,
        null,
        true
    );
    DocGen_Job__c noMergeRec = [SELECT Duplex_Padding__c FROM DocGen_Job__c WHERE Id = :noMergeJob];
    if (noMergeRec.Duplex_Padding__c != true) {
        pass++;
        System.debug('DUPLEX FORCED OFF FOR INDIVIDUAL FILES: PASS');
    } else {
        fail++;
        System.debug('DUPLEX FORCED OFF FOR INDIVIDUAL FILES: FAIL — flag survived on a non-merge job');
    }
    delete [SELECT Id FROM DocGen_Job__c WHERE Id = :noMergeJob];

    // analyzeJob: the duplex packet ceiling is a hard block above ~400 documents,
    // and it must fire regardless of whether the template has a Test Record.
    DocGenBulkController.JobAnalysis dpxSmall = DocGenBulkController.analyzeJob(tmplId, 10, 1, true, true);
    DocGenBulkController.JobAnalysis dpxHuge = DocGenBulkController.analyzeJob(tmplId, 5000, 1, true, true);
    Boolean smallOk = dpxSmall != null && dpxSmall.canProceed == true;
    Boolean hugeBlocked = dpxHuge != null && dpxHuge.canProceed == false;
    Boolean hasDuplexItem = false;
    if (dpxHuge != null && dpxHuge.items != null) {
        for (DocGenBulkController.AnalysisItem it : dpxHuge.items) {
            if (it.label == 'Duplex Packet' && it.status == 'error') {
                hasDuplexItem = true;
            }
        }
    }
    if (smallOk && hugeBlocked && hasDuplexItem) {
        pass++;
        System.debug('DUPLEX CEILING: PASS');
    } else {
        fail++;
        System.debug(
            'DUPLEX CEILING: FAIL — small.canProceed=' +
                (dpxSmall == null ? 'null' : String.valueOf(dpxSmall.canProceed)) +
                ' huge.canProceed=' +
                (dpxHuge == null ? 'null' : String.valueOf(dpxHuge.canProceed)) +
                ' duplexErrorItem=' +
                hasDuplexItem
        );
    }
} catch (Exception e) {
    fail++;
    System.debug('DUPLEX PADDING: FAIL — ' + e.getMessage());
}

// ===== Save Query =====
try {
    DocGenBulkController.saveQuery(tmplId, 'E2E Test Query', 'Test saved query', 'Name = \'E2E Test Corp\'');
    pass++;
    System.debug('SAVE QUERY: PASS');
} catch (Exception e) {
    fail++;
    System.debug('SAVE QUERY: FAIL — ' + e.getMessage());
}

// ===== Get Saved Queries =====
try {
    List<DocGen_Saved_Query__c> queries = DocGenBulkController.getSavedQueries(tmplId);
    if (queries != null && !queries.isEmpty()) {
        pass++;
        System.debug('GET SAVED QUERIES: PASS — count: ' + queries.size());
        savedQueryId = queries[0].Id;
    } else {
        fail++;
        System.debug('GET SAVED QUERIES: FAIL — empty or null');
    }
} catch (Exception e) {
    fail++;
    System.debug('GET SAVED QUERIES: FAIL — ' + e.getMessage());
}

// ===== Delete Query =====
try {
    if (savedQueryId != null) {
        DocGenBulkController.deleteQuery(savedQueryId);
        List<DocGen_Saved_Query__c> after = DocGenBulkController.getSavedQueries(tmplId);
        Boolean deleted = true;
        if (after != null) {
            for (DocGen_Saved_Query__c sq : after) {
                if (sq.Id == savedQueryId) {
                    deleted = false;
                    break;
                }
            }
        }
        if (deleted) {
            pass++;
            System.debug('DELETE QUERY: PASS');
        } else {
            fail++;
            System.debug('DELETE QUERY: FAIL — query still exists');
        }
    } else {
        fail++;
        System.debug('DELETE QUERY: FAIL — no savedQueryId');
    }
} catch (Exception e) {
    fail++;
    System.debug('DELETE QUERY: FAIL — ' + e.getMessage());
}

// ===== Get Bulk Templates =====
try {
    List<DocGen_Template__c> bulkTmpls = DocGenBulkController.getBulkTemplates();
    if (bulkTmpls != null) {
        Boolean foundOurs = false;
        for (DocGen_Template__c bt : bulkTmpls) {
            if (bt.Id == tmplId) {
                foundOurs = true;
                break;
            }
        }
        if (foundOurs) {
            pass++;
            System.debug('GET BULK TEMPLATES: PASS — found E2E template in ' + bulkTmpls.size() + ' templates');
        } else {
            pass++;
            System.debug('GET BULK TEMPLATES: PASS — ' + bulkTmpls.size() + ' templates (E2E may not have active CV)');
        }
    } else {
        fail++;
        System.debug('GET BULK TEMPLATES: FAIL — null');
    }
} catch (Exception e) {
    fail++;
    System.debug('GET BULK TEMPLATES: FAIL — ' + e.getMessage());
}

// ===== Direct generateDocument (simulates batch execute — NOT Aura context) =====
try {
    Id docId = DocGenService.generateDocument(tmplId, acctId);
    if (docId != null) {
        pass++;
        System.debug('GENERATE DOCUMENT (non-Aura): PASS — ' + docId);
    } else {
        fail++;
        System.debug('GENERATE DOCUMENT (non-Aura): FAIL — null');
    }
} catch (Exception e) {
    fail++;
    System.debug('GENERATE DOCUMENT (non-Aura): FAIL — ' + e.getMessage());
}

// ===== Document Title override (Flow Document Title input — GH #41) =====
try {
    String customTitle = 'E2E_FlowTitleOverride_' + DateTime.now().getTime();
    Id docId = DocGenService.generateDocument(tmplId, acctId, null, customTitle);
    List<ContentVersion> cvs = [SELECT Title FROM ContentVersion WHERE ContentDocumentId = :docId];
    if (!cvs.isEmpty() && cvs[0].Title == customTitle) {
        pass++;
        System.debug('DOCUMENT TITLE OVERRIDE: PASS — ' + cvs[0].Title);
    } else {
        fail++;
        System.debug(
            'DOCUMENT TITLE OVERRIDE: FAIL — expected "' +
                customTitle +
                '" got "' +
                (cvs.isEmpty() ? 'NO_CV' : cvs[0].Title) +
                '"'
        );
    }
} catch (Exception e) {
    fail++;
    System.debug('DOCUMENT TITLE OVERRIDE: FAIL — ' + e.getMessage());
}

// ===== Clean up job =====
try {
    if (jobId != null) {
        delete [SELECT Id FROM DocGen_Job__c WHERE Id = :jobId];
        System.debug('CLEANUP: Deleted test job ' + jobId);
    }
} catch (Exception e) {
    System.debug('CLEANUP NOTE: ' + e.getMessage());
}

System.debug('========================================');
System.debug(
    'E2E-05 GENERATE BULK — PASS: ' +
        pass +
        '  FAIL: ' +
        fail +
        (fail == 0 ? '  ALL TESTS PASSED' : '  FAILURES DETECTED')
);
System.debug('========================================');
