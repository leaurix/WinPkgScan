@{
    # Fail the build on warnings and errors.
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # This is an interactive console tool. Write-Host is used on purpose
        # for coloured output and to keep the results off the pipeline.
        'PSAvoidUsingWriteHost'
    )
}
