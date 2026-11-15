/** Ordered private file versions that make up a committed PDF revision. */
public class ApexPdfAppendManifest {
    public static final String DESCRIPTION = 'Portwood PDF Range Manifest v1';
    public static final String CHUNK_DESCRIPTION = 'Portwood PDF Append Chunk v1';

    public String runKey;
    public Integer sourceCount;
    public Integer pages;
    public Integer totalBytes;
    public List<Chunk> chunks;

    public class Chunk {
        public Id versionId;
        public Integer size;

        public Chunk(Id versionId, Integer size) {
            this.versionId = versionId;
            this.size = size;
        }
    }
}
