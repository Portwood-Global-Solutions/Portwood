import prepareNativeWordDocument from '@salesforce/apex/DocGenController.prepareNativeWordDocument';
import getNativeWordDocumentStatus from '@salesforce/apex/DocGenController.getNativeWordDocumentStatus';

/** A Salesforce job copies static DOCX packages without an Aura byte payload. */
export async function generateStaticWord(templateId, recordId, saveToRecord = false) {
    const jobId = await prepareNativeWordDocument({ templateId, recordId, saveToRecord });
    if (!jobId) return null;
    for (let attempt = 0; attempt < 120; attempt++) {
        // eslint-disable-next-line no-await-in-loop
        const result = await getNativeWordDocumentStatus({ jobId });
        if (result.status === 'Completed') return result.requiresMerge ? null : result;
        if (result.status === 'Failed' || result.status === 'Aborted') {
            throw new Error(result.error || 'Word document generation failed.');
        }
        // eslint-disable-next-line no-await-in-loop
        await new Promise((resolve) => setTimeout(resolve, 1000));
    }
    throw new Error('Word document generation is still running. Try again in a moment.');
}
