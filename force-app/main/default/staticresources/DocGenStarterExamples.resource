{
  "quote": {
    "title": "Quote PDF",
    "objectApiName": "Quote",
    "description": "A Salesforce quote with products, line discounts, tax, shipping, and native quote totals.",
    "query": "{\"v\": 3, \"root\": \"Quote\", \"nodes\": [{\"id\": \"n0\", \"object\": \"Quote\", \"fields\": [\"Name\", \"QuoteNumber\", \"ExpirationDate\", \"Status\", \"Subtotal\", \"TotalPrice\", \"Tax\", \"ShippingHandling\", \"GrandTotal\"], \"parentFields\": [\"Account.Name\", \"Account.BillingCity\", \"Account.BillingState\"], \"parentNode\": null, \"lookupField\": null, \"relationshipName\": null}, {\"id\": \"n1\", \"object\": \"QuoteLineItem\", \"fields\": [\"Quantity\", \"UnitPrice\", \"Discount\", \"TotalPrice\", \"Description\"], \"parentFields\": [\"Product2.Name\"], \"parentNode\": \"n0\", \"lookupField\": \"QuoteId\", \"relationshipName\": \"QuoteLineItems\", \"orderBy\": \"SortOrder ASC\"}]}",
    "html": "<!DOCTYPE html><html><head><meta charset=\"UTF-8\"/><title>Quote</title><style>@page { size: Letter; margin: 0.55in; @bottom-right { content: \"Page \" counter(page); font: 8pt Helvetica; color: #526475; } }\nbody { font: 10pt Helvetica, Arial, sans-serif; color: #183452; line-height: 1.45; }\nh1 { font-size: 27pt; line-height: 1.15; margin: 16pt 0 8pt; }\nh2 { font-size: 14pt; margin: 24pt 0 8pt; color: #206b72; }\np { margin: 5pt 0; } .mast { border-bottom: 3pt solid #206b72; padding-bottom: 10pt; font-size: 11pt; }\n.mast span { color: #526475; } .intro { color: #526475; margin-bottom: 16pt; }\ntable { width: 100%; border-collapse: collapse; } th { background: #183452; color: white; font-size: 9pt; padding: 8pt; text-align: left; }\ntd { padding: 8pt; border-bottom: 0.6pt solid #d8e1ea; vertical-align: top; } .num { text-align: right; }\n.summary { margin: 16pt 0; background: #edf5f5; } .summary td { padding: 14pt; border: 0; }\n.summary strong { display: block; font-size: 19pt; color: #206b72; } .label { font-size: 9pt; color: #526475; }\n.note { padding: 10pt; background: #f3f6f9; color: #526475; margin-top: 14pt; font-size: 9pt; }\n.total td { background: #edf5f5; font-weight: bold; } tr { page-break-inside: avoid; } thead { display: table-header-group; }\nbody { font-size: 9.5pt; line-height: 1.35; } h2 { margin-top: 20pt; } .summary td { padding: 12pt; } td { padding: 7pt; } .quote-lines { -fs-table-paginate: paginate; } .quote-totals { width: 65%; margin: 10pt 0 0 auto; page-break-inside: avoid; } .quote-totals td { padding: 5pt 7pt; } .note { page-break-inside: avoid; }</style></head><body><div class=\"mast\"><b>Portwood</b><span> / Quote</span></div><h1>{Name}</h1><p class=\"intro\">Quote {QuoteNumber} / Prepared for {Account.Name}</p>\n<table class=\"summary\"><tr><td><span class=\"label\">Grand total</span><strong>{GrandTotal:currency}</strong></td><td><span class=\"label\">Valid through</span><strong>{ExpirationDate:MMM dd, yyyy}</strong></td></tr></table>\n<table><tr><td><b>Customer</b><p>{Account.Name}</p><p>{Account.BillingCity}, {Account.BillingState}</p></td><td><b>Quote details</b><p>{Status}</p><p>{COUNT:QuoteLineItems} products or services</p></td></tr></table>\n<h2>Products and services</h2><table class=\"quote-lines\"><thead><tr><th style=\"width:38%\">Product or service</th><th class=\"num\">Qty</th><th class=\"num\">Unit price</th><th class=\"num\">Discount %</th><th class=\"num\">Line total</th></tr></thead><tbody><tr><td>{#QuoteLineItems}<b>{Product2.Name}</b><p>{Description}</p></td><td class=\"num\">{Quantity:#,##0.00}</td><td class=\"num\">{UnitPrice:currency}</td><td class=\"num\">{Discount:#,##0.00}</td><td class=\"num\">{TotalPrice:currency}{/QuoteLineItems}</td></tr></tbody></table>\n{^QuoteLineItems.records}<p class=\"note\">No products have been added to this quote. Add quote line items, then generate this document again.</p>{/QuoteLineItems.records}\n<table class=\"quote-totals\"><tr><td>Subtotal before line discounts</td><td class=\"num\">{Subtotal:currency}</td></tr><tr><td>Products after line discounts</td><td class=\"num\">{TotalPrice:currency}</td></tr><tr><td>Tax</td><td class=\"num\">{Tax:currency}</td></tr><tr><td>Shipping and handling</td><td class=\"num\">{ShippingHandling:currency}</td></tr><tr class=\"total\"><td>Grand total</td><td class=\"num\">{GrandTotal:currency}</td></tr></table>\n<p class=\"note\">Pricing and totals come from this Salesforce quote. Tax and shipping are the saved quote amounts; Portwood does not calculate or add charges. Confirm pricing, validity, and terms with your account team before sharing.</p></body></html>",
    "sample": {
      "Name": "Customer Success Launch",
      "QuoteNumber": "Q-001024",
      "Account": {
        "Name": "Northstar Manufacturing (fictional)",
        "BillingCity": "Indianapolis",
        "BillingState": "IN"
      },
      "Status": "Draft",
      "ExpirationDate": "2026-11-30",
      "Subtotal": 24500,
      "TotalPrice": 23100,
      "Tax": 600,
      "ShippingHandling": 150,
      "GrandTotal": 23850,
      "QuoteLineItems": {
        "records": [
          {
            "Product2": {
              "Name": "Launch workshop"
            },
            "Description": "Discovery, planning, and success criteria.",
            "Quantity": 1,
            "UnitPrice": 4500,
            "TotalPrice": 4500,
            "Discount": 0
          },
          {
            "Product2": {
              "Name": "Implementation services"
            },
            "Description": "Configure and launch the agreed solution.",
            "Quantity": 40,
            "UnitPrice": 350,
            "TotalPrice": 12600,
            "Discount": 10
          },
          {
            "Product2": {
              "Name": "Success support"
            },
            "Description": "Three months of guided adoption.",
            "Quantity": 3,
            "UnitPrice": 2000,
            "TotalPrice": 6000,
            "Discount": 0
          }
        ]
      }
    }
  },
  "opportunity": {
    "title": "Opportunity proposal",
    "objectApiName": "Opportunity",
    "description": "A sales proposal with products, quantities, pricing, and a calculated total.",
    "query": "{\"v\": 3, \"root\": \"Opportunity\", \"nodes\": [{\"id\": \"n0\", \"object\": \"Opportunity\", \"fields\": [\"Name\", \"Amount\", \"StageName\", \"CloseDate\"], \"parentFields\": [\"Account.Name\", \"Account.BillingCity\", \"Account.BillingState\", \"Owner.Name\"], \"parentNode\": null, \"lookupField\": null, \"relationshipName\": null}, {\"id\": \"n1\", \"object\": \"OpportunityLineItem\", \"fields\": [\"Quantity\", \"UnitPrice\", \"TotalPrice\", \"Description\"], \"parentFields\": [\"Product2.Name\"], \"parentNode\": \"n0\", \"lookupField\": \"OpportunityId\", \"relationshipName\": \"OpportunityLineItems\", \"orderBy\": \"SortOrder ASC\"}]}",
    "html": "<!DOCTYPE html><html><head><meta charset=\"UTF-8\"/><title>Opportunity proposal</title><style>@page { size: Letter; margin: 0.55in; @bottom-right { content: \"Page \" counter(page); font: 8pt Helvetica; color: #526475; } }\nbody { font: 10pt Helvetica, Arial, sans-serif; color: #183452; line-height: 1.45; }\nh1 { font-size: 27pt; line-height: 1.15; margin: 16pt 0 8pt; }\nh2 { font-size: 14pt; margin: 24pt 0 8pt; color: #206b72; }\np { margin: 5pt 0; } .mast { border-bottom: 3pt solid #206b72; padding-bottom: 10pt; font-size: 11pt; }\n.mast span { color: #526475; } .intro { color: #526475; margin-bottom: 16pt; }\ntable { width: 100%; border-collapse: collapse; } th { background: #183452; color: white; font-size: 9pt; padding: 8pt; text-align: left; }\ntd { padding: 8pt; border-bottom: 0.6pt solid #d8e1ea; vertical-align: top; } .num { text-align: right; }\n.summary { margin: 16pt 0; background: #edf5f5; } .summary td { padding: 14pt; border: 0; }\n.summary strong { display: block; font-size: 19pt; color: #206b72; } .label { font-size: 9pt; color: #526475; }\n.note { padding: 10pt; background: #f3f6f9; color: #526475; margin-top: 14pt; font-size: 9pt; }\n.total td { background: #edf5f5; font-weight: bold; } tr { page-break-inside: avoid; } thead { display: table-header-group; }\n</style></head><body><div class=\"mast\"><b>Portwood</b><span> / Opportunity proposal</span></div><h1>{Name}</h1><p class=\"intro\">Prepared for {Account.Name} / Opportunity owner: {Owner.Name}</p>\n<table class=\"summary\"><tr><td><span class=\"label\">Proposal value</span><strong>{SUM:OpportunityLineItems.TotalPrice:currency}</strong></td><td><span class=\"label\">Expected close</span><strong>{CloseDate:MMM dd, yyyy}</strong></td></tr></table>\n<table><tr><td><b>Customer</b><p>{Account.Name}</p><p>{Account.BillingCity}, {Account.BillingState}</p></td><td><b>Sales status</b><p>{StageName}</p><p>{COUNT:OpportunityLineItems} products or services</p></td></tr></table>\n<h2>Products and services</h2><table><thead><tr><th style=\"width:46%\">Product or service</th><th class=\"num\">Quantity</th><th class=\"num\">Unit price</th><th class=\"num\">Line total</th></tr></thead><tbody><tr><td>{#OpportunityLineItems}<b>{Product2.Name}</b><p>{Description}</p></td><td class=\"num\">{Quantity:number}</td><td class=\"num\">{UnitPrice:currency}</td><td class=\"num\">{TotalPrice:currency}{/OpportunityLineItems}</td></tr>\n<tr class=\"total\"><td colspan=\"3\">Products and services total</td><td class=\"num\">{SUM:OpportunityLineItems.TotalPrice:currency}</td></tr></tbody></table>\n{^OpportunityLineItems.records}<p class=\"note\">No products have been added to this opportunity. Add products to the opportunity, then generate this document again.</p>{/OpportunityLineItems.records}\n<h2>Next steps</h2><p>Review the products and pricing with your account team. Confirm the scope and target close date before sending a final proposal.</p><p class=\"note\">This proposal summarizes Salesforce opportunity products. Taxes, shipping, discounts outside the line totals, and contractual terms are not added by this template.</p></body></html>",
    "sample": {
      "Name": "Northstar - Customer Success Launch",
      "Account": {
        "Name": "Northstar Manufacturing (fictional)",
        "BillingCity": "Indianapolis",
        "BillingState": "IN"
      },
      "Owner": {
        "Name": "Alex Morgan"
      },
      "StageName": "Proposal / Price Quote",
      "CloseDate": "2026-11-30",
      "Amount": 24500,
      "OpportunityLineItems": {
        "records": [
          {
            "Product2": {
              "Name": "Launch workshop"
            },
            "Description": "Discovery, planning, and success criteria.",
            "Quantity": 1,
            "UnitPrice": 4500,
            "TotalPrice": 4500
          },
          {
            "Product2": {
              "Name": "Implementation services"
            },
            "Description": "Configure and launch the agreed solution.",
            "Quantity": 40,
            "UnitPrice": 350,
            "TotalPrice": 14000
          },
          {
            "Product2": {
              "Name": "Success support"
            },
            "Description": "Three months of guided adoption.",
            "Quantity": 3,
            "UnitPrice": 2000,
            "TotalPrice": 6000
          }
        ]
      }
    }
  },
  "account": {
    "title": "Account summary",
    "objectApiName": "Account",
    "description": "An account briefing with open opportunities, open cases, and key contacts.",
    "query": "{\"v\": 3, \"root\": \"Account\", \"nodes\": [{\"id\": \"n0\", \"object\": \"Account\", \"fields\": [\"Name\", \"Industry\", \"Phone\"], \"parentFields\": [\"Owner.Name\"], \"parentNode\": null, \"lookupField\": null, \"relationshipName\": null}, {\"id\": \"n1\", \"object\": \"Opportunity\", \"fields\": [\"Name\", \"StageName\", \"Amount\", \"CloseDate\"], \"parentFields\": [], \"parentNode\": \"n0\", \"lookupField\": \"AccountId\", \"relationshipName\": \"Opportunities\", \"where\": \"IsClosed = false\", \"orderBy\": \"CloseDate ASC\"}, {\"id\": \"n2\", \"object\": \"Case\", \"fields\": [\"CaseNumber\", \"Subject\", \"Priority\", \"Status\"], \"parentFields\": [], \"parentNode\": \"n0\", \"lookupField\": \"AccountId\", \"relationshipName\": \"Cases\", \"where\": \"IsClosed = false\", \"orderBy\": \"CreatedDate DESC\"}, {\"id\": \"n3\", \"object\": \"Contact\", \"fields\": [\"Name\", \"Title\", \"Email\"], \"parentFields\": [], \"parentNode\": \"n0\", \"lookupField\": \"AccountId\", \"relationshipName\": \"Contacts\", \"orderBy\": \"Name ASC\"}]}",
    "html": "<!DOCTYPE html><html><head><meta charset=\"UTF-8\"/><title>Account summary</title><style>@page { size: Letter; margin: 0.55in; @bottom-right { content: \"Page \" counter(page); font: 8pt Helvetica; color: #526475; } }\nbody { font: 10pt Helvetica, Arial, sans-serif; color: #183452; line-height: 1.45; }\nh1 { font-size: 27pt; line-height: 1.15; margin: 16pt 0 8pt; }\nh2 { font-size: 14pt; margin: 24pt 0 8pt; color: #206b72; }\np { margin: 5pt 0; } .mast { border-bottom: 3pt solid #206b72; padding-bottom: 10pt; font-size: 11pt; }\n.mast span { color: #526475; } .intro { color: #526475; margin-bottom: 16pt; }\ntable { width: 100%; border-collapse: collapse; } th { background: #183452; color: white; font-size: 9pt; padding: 8pt; text-align: left; }\ntd { padding: 8pt; border-bottom: 0.6pt solid #d8e1ea; vertical-align: top; } .num { text-align: right; }\n.summary { margin: 16pt 0; background: #edf5f5; } .summary td { padding: 14pt; border: 0; }\n.summary strong { display: block; font-size: 19pt; color: #206b72; } .label { font-size: 9pt; color: #526475; }\n.note { padding: 10pt; background: #f3f6f9; color: #526475; margin-top: 14pt; font-size: 9pt; }\n.total td { background: #edf5f5; font-weight: bold; } tr { page-break-inside: avoid; } thead { display: table-header-group; }\nbody { font-size: 9.5pt; } h2 { margin-top: 18pt; } td { padding: 7pt; } .summary td { padding: 12pt; } .note { margin-top: 10pt; page-break-inside: avoid; }</style></head><body><div class=\"mast\"><b>Portwood</b><span> / Account summary</span></div><h1>{Name}</h1><p class=\"intro\">Customer activity, open opportunities, and open support cases in one place.</p>\n<table class=\"summary\"><tr><td><span class=\"label\">Open pipeline</span><strong>{SUM:Opportunities.Amount:currency}</strong></td><td><span class=\"label\">Open opportunities</span><strong>{COUNT:Opportunities}</strong></td><td><span class=\"label\">Open cases</span><strong>{COUNT:Cases}</strong></td></tr></table>\n<table><tr><td><b>Account owner</b><p>{Owner.Name}</p></td><td><b>Industry</b><p>{Industry}</p></td><td><b>Phone</b><p>{Phone}</p></td></tr></table>\n<h2>Open opportunities</h2><table><thead><tr><th style=\"width:42%\">Opportunity</th><th>Stage</th><th>Close date</th><th class=\"num\">Amount</th></tr></thead><tbody><tr><td>{#Opportunities}{Name}</td><td>{StageName}</td><td>{CloseDate:MMM dd, yyyy}</td><td class=\"num\">{Amount:currency}{/Opportunities}</td></tr></tbody></table>{^Opportunities.records}<p class=\"note\">No open opportunities for this account.</p>{/Opportunities.records}\n<h2>Open support cases</h2><table><thead><tr><th>Case</th><th style=\"width:45%\">Subject</th><th>Priority</th><th>Status</th></tr></thead><tbody><tr><td>{#Cases}{CaseNumber}</td><td>{Subject}</td><td>{Priority}</td><td>{Status}{/Cases}</td></tr></tbody></table>{^Cases.records}<p class=\"note\">No open support cases for this account.</p>{/Cases.records}\n<h2>Key contacts</h2><table><thead><tr><th>Name</th><th>Role</th><th>Email</th></tr></thead><tbody><tr><td>{#Contacts}{Name}</td><td>{Title}</td><td>{Email}{/Contacts}</td></tr></tbody></table>{^Contacts.records}<p class=\"note\">No contacts for this account.</p>{/Contacts.records}\n<p class=\"note\">Opportunities exclude closed deals. Cases exclude closed cases. Counts and totals reflect the records the generating user can access.</p></body></html>",
    "sample": {
      "Name": "Northstar Manufacturing (fictional)",
      "Industry": "Manufacturing",
      "Phone": "(317) 555-0142",
      "Owner": {
        "Name": "Alex Morgan"
      },
      "Opportunities": {
        "records": [
          {
            "Name": "Customer Success Launch",
            "StageName": "Proposal / Price Quote",
            "Amount": 24500,
            "CloseDate": "2026-11-30"
          },
          {
            "Name": "Operations Expansion",
            "StageName": "Qualification",
            "Amount": 48000,
            "CloseDate": "2026-12-18"
          }
        ]
      },
      "Cases": {
        "records": [
          {
            "CaseNumber": "00001024",
            "Subject": "Confirm rollout access for the operations team",
            "Priority": "High",
            "Status": "Working"
          },
          {
            "CaseNumber": "00001031",
            "Subject": "Review monthly reporting requirements",
            "Priority": "Medium",
            "Status": "New"
          }
        ]
      },
      "Contacts": {
        "records": [
          {
            "Name": "Jordan Ellis",
            "Title": "VP of Operations",
            "Email": "jordan@example.com"
          },
          {
            "Name": "Taylor Reed",
            "Title": "Customer Success Lead",
            "Email": "taylor@example.com"
          }
        ]
      }
    }
  }
}