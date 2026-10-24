Choose a format and run size that fit the document. Test representative data before a large run.

| Item                                       | Practical limit or behavior                                                                       |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------- |
| Uploaded template file                     | Uploader limit: **10 MB**; compress large pictures                                                |
| PDF prepared for uploaded-document signing | **2 MB**, **50 pages**, **10 recipients**, **100 fields**                                         |
| PDF/HTML/Canvas output                     | PDF; browser preview and final PDF can differ                                                     |
| Word template output                       | Word or PDF                                                                                       |
| PowerPoint / Excel template output         | Native Office file; no conversion to PDF                                                          |
| Bulk native Office or fillable PDF form    | Use **Individual Files**                                                                          |
| Large native Office save                   | May require downloading and then using the shown drag-to-attach uploader                          |
| Duplex combined packet                     | Size-dependent estimate; split the run or use Individual Files if it exceeds the available budget |
| Custom fonts per document                  | Up to **16 distinct approved faces**                                                              |

#### Large data is not the same as a large file

A few rows containing large pictures or rich text can cost more memory than thousands of short rows. Keep data selection focused and use sensible image dimensions.

Portwood has background paths and browser assembly for supported scenarios, but they do not make every format unlimited. Flow and Apex do not have the browser assembly available to an interactive runner.

#### Features to test particularly carefully

- Canvas is **Beta**.
- Fillable PDF templates are **in testing**.
- Excel and PowerPoint templates are **Alpha**.
- Modern web CSS and inline SVG do not have the same support in Salesforce's PDF renderer as in a browser.
- Built-in PDF fonts do not cover every character. Use a supported, approved face and test the actual text.

Start with a small run and increase it only after inspecting output and job results. Use [job history](#job-history) and [document troubleshooting](#fix-document) when a size-related error appears.
