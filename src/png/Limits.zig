//! Resource budgets for PNG image operations. Each field limits one category independently; zero
//! permits no resources in that category. Dimensions and encoded-input size have separate options.
//! Work units count the operations described by each codec entry point, not elapsed time.

/// Maximum pixels for the selected output: a crop, decoded frame set or playback canvas. An
/// excluded animation poster is also checked independently from the decoded frame set.
maximum_pixels: usize = 64 * 1024 * 1024,
/// Selected output bytes: decoded pixels and auxiliary owners, or complete encoded output. Applies
/// to owned and caller-reserved results; encoded source storage is excluded. Decoded allocation
/// alignment padding and allocator overhead are excluded.
maximum_output_bytes: usize = 512 * 1024 * 1024,
/// Maximum simultaneously live temporary bytes requested from scratch storage. Includes any caller
/// retention span charged by the operation; allocator overhead is excluded.
maximum_scratch_bytes: usize = 192 * 1024 * 1024,
/// Maximum work units charged by the selected operation. Traversal, filtering and metadata have
/// operation-specific counts; compression match-search effort is controlled by Compression.
maximum_work_units: usize = 1024 * 1024 * 1024,
/// Maximum records charged by the operation: PNG chunks and, where metadata is validated, selected
/// ICC/TIFF records. This is a count, not a byte limit.
maximum_records: usize = 1024 * 1024,
/// Maximum metadata bytes charged by the operation. Inspection counts encoded ancillary payloads
/// and fdAT sequence words. Encoding also counts selected raw metadata and format/control headers.
/// Metadata queries have separate traversal limits; profile/text expansion is bounded by the
/// caller's destination capacity.
maximum_metadata_bytes: usize = 1024 * 1024,

/// Resource policy exhaustion, distinct from a supplied allocator's allocation failure.
pub const Error = error{
    /// Encoded source bytes exceed the selected operation's source admission.
    EncodedBudgetExceeded,
    /// The selected output contains too many pixels.
    PixelBudgetExceeded,
    /// The selected output bytes exceed output admission.
    OutputBudgetExceeded,
    /// Live temporary requests would exceed scratch admission.
    ScratchBudgetExceeded,
    /// Documented format work units exceed this operation's admission.
    WorkBudgetExceeded,
    /// Structural records or aggregate metadata bytes exceed admission.
    MetadataLimitExceeded,
};
